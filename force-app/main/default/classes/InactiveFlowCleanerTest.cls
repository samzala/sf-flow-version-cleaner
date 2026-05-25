/**
 * InactiveFlowCleanerTest
 *
 * Test class for InactiveFlowCleaner (Batch 2).
 * Covers: full teardown happy path, dry run, version deletion failures,
 * callout exceptions, multi-definition scenarios, and log record assertions.
 *
 * Note: FlowInterview records cannot be inserted via DML in Apex tests
 * so the interview deletion path is covered via the empty-result path only.
 */
@IsTest
private class InactiveFlowCleanerTest {

    // ── Helpers ───────────────────────────────────────────────────────────────

    private static FlowVersionCleaner.FlowVersion buildVersion(
        String id, String definitionId, String definitionName,
        Integer versionNumber, String status
    ) {
        FlowVersionCleaner.FlowVersion fv = new FlowVersionCleaner.FlowVersion();
        fv.id                  = id;
        fv.definitionId        = definitionId;
        fv.definitionName      = definitionName;
        fv.versionNumber       = versionNumber;
        fv.status              = status;
        fv.versionLastModified = DateTime.now().addMonths(-6);
        return fv;
    }

    private static Map<String, List<FlowVersionCleaner.FlowVersion>> buildPlan(
        String defId, String defName, Integer versionCount
    ) {
        List<FlowVersionCleaner.FlowVersion> versions = new List<FlowVersionCleaner.FlowVersion>();
        for (Integer i = 1; i <= versionCount; i++) {
            versions.add(buildVersion(defId + '_V' + i, defId, defName, i, 'Obsolete'));
        }
        return new Map<String, List<FlowVersionCleaner.FlowVersion>>{ defId => versions };
    }

    // ── Mocks ─────────────────────────────────────────────────────────────────

    // Returns configurable status code for all DELETE requests.
    private class TeardownMock implements HttpCalloutMock {
        private Integer deleteStatusCode;
        public TeardownMock(Integer deleteStatusCode) {
            this.deleteStatusCode = deleteStatusCode;
        }
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(deleteStatusCode);
            res.setBody('');
            return res;
        }
    }

    // Returns 400 for all DELETE requests to simulate version deletion failure.
    private class VersionFailMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(400);
            res.setBody('{"errorCode":"DELETE_FAILED","message":"Cannot delete"}');
            return res;
        }
    }

    // Throws CalloutException for all DELETE requests.
    private class VersionDeleteExceptionMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            throw new System.CalloutException('Simulated version delete failure');
        }
    }

    // ── Happy path ────────────────────────────────────────────────────────────

    @IsTest
    static void testFullTeardown_HappyPath() {
        Map<String, List<FlowVersionCleaner.FlowVersion>> plan = buildPlan('DEF1', 'DeadFlow', 3);
        Test.setMock(HttpCalloutMock.class, new TeardownMock(204));
        Test.startTest();
        Database.executeBatch(new InactiveFlowCleaner(plan, false, null), 1);
        Test.stopTest();

        List<Flow_Version_Cleaner_Log__c> logs = [
            SELECT Flow_Name__c, Version_Number__c, Flow_Status__c, Action__c
            FROM Flow_Version_Cleaner_Log__c
            WHERE Action__c = 'Teardown'
            ORDER BY Version_Number__c ASC
        ];
        System.assertEquals(3, logs.size(), 'Expected 3 Teardown log entries');
        System.assertEquals('DeadFlow', logs[0].Flow_Name__c, 'Flow name should be populated');
        System.assertEquals(1, logs[0].Version_Number__c, 'v1 should be logged');
        System.assertEquals(2, logs[1].Version_Number__c, 'v2 should be logged');
        System.assertEquals(3, logs[2].Version_Number__c, 'v3 should be logged');
        System.assertEquals('Obsolete', logs[0].Flow_Status__c, 'Status should be populated');
    }

    // ── Dry run ───────────────────────────────────────────────────────────────

    @IsTest
    static void testFullTeardown_DryRun() {
        Map<String, List<FlowVersionCleaner.FlowVersion>> plan = buildPlan('DEF1', 'DeadFlow', 3);
        Test.setMock(HttpCalloutMock.class, new TeardownMock(204));
        Test.startTest();
        Database.executeBatch(new InactiveFlowCleaner(plan, true, null), 1);
        Test.stopTest();

        // No Teardown records — dry run only creates Dry Run records
        List<Flow_Version_Cleaner_Log__c> teardownLogs = [
            SELECT Id FROM Flow_Version_Cleaner_Log__c WHERE Action__c = 'Teardown'
        ];
        System.assertEquals(0, teardownLogs.size(), 'No real deletes in dry run');

        List<Flow_Version_Cleaner_Log__c> dryRunLogs = [
            SELECT Flow_Name__c, Version_Number__c, Flow_Status__c
            FROM Flow_Version_Cleaner_Log__c
            WHERE Action__c = 'Dry Run'
            ORDER BY Version_Number__c ASC
        ];
        System.assertEquals(3, dryRunLogs.size(), 'Expected 3 Dry Run log entries');
        System.assertEquals('DeadFlow', dryRunLogs[0].Flow_Name__c, 'Flow name should be populated');
        System.assertEquals(1, dryRunLogs[0].Version_Number__c, 'v1 should be logged');
        System.assertEquals('Obsolete', dryRunLogs[0].Flow_Status__c, 'Status should be populated');
    }

    // ── Version deletion fails — non-204 ──────────────────────────────────────

    @IsTest
    static void testFullTeardown_VersionDeletionFails_Non204() {
        Map<String, List<FlowVersionCleaner.FlowVersion>> plan = buildPlan('DEF1', 'DeadFlow', 2);
        Test.setMock(HttpCalloutMock.class, new VersionFailMock());
        Test.startTest();
        Database.executeBatch(new InactiveFlowCleaner(plan, false, null), 1);
        Test.stopTest();

        List<Flow_Version_Cleaner_Log__c> failedLogs = [
            SELECT Flow_Name__c, Version_Number__c, Message__c
            FROM Flow_Version_Cleaner_Log__c
            WHERE Action__c = 'Teardown Failed'
            AND Flow_Name__c != null
        ];
        System.assertNotEquals(0, failedLogs.size(), 'Expected teardown failed log entries');
        System.assertEquals('DeadFlow', failedLogs[0].Flow_Name__c, 'Flow name should be populated');
        System.assertNotEquals(null, failedLogs[0].Version_Number__c, 'Version number should be populated');
        System.assert(failedLogs[0].Message__c.contains('HTTP 400'), 'HTTP status should be in message');
    }

    // ── Version deletion fails — callout exception ────────────────────────────

    @IsTest
    static void testFullTeardown_VersionDeletionFails_CalloutException() {
        Map<String, List<FlowVersionCleaner.FlowVersion>> plan = buildPlan('DEF1', 'DeadFlow', 2);
        Test.setMock(HttpCalloutMock.class, new VersionDeleteExceptionMock());
        Test.startTest();
        Database.executeBatch(new InactiveFlowCleaner(plan, false, null), 1);
        Test.stopTest();

        List<Flow_Version_Cleaner_Log__c> failedLogs = [
            SELECT Flow_Name__c, Version_Number__c, Message__c
            FROM Flow_Version_Cleaner_Log__c
            WHERE Action__c = 'Teardown Failed'
            AND Flow_Name__c != null
        ];
        System.assertNotEquals(0, failedLogs.size(), 'Expected teardown failed log entries');
        System.assert(failedLogs[0].Message__c.contains('Simulated'), 'Exception message should be logged');
    }

    // ── Multiple definitions ──────────────────────────────────────────────────

    @IsTest
    static void testFullTeardown_MultipleDefinitions() {
        Map<String, List<FlowVersionCleaner.FlowVersion>> plan = buildPlan('DEF1', 'FlowA', 2);
        plan.put('DEF2', new List<FlowVersionCleaner.FlowVersion>{
            buildVersion('DEF2_V1', 'DEF2', 'FlowB', 1, 'Obsolete'),
            buildVersion('DEF2_V2', 'DEF2', 'FlowB', 2, 'Obsolete')
        });
        Test.setMock(HttpCalloutMock.class, new TeardownMock(204));
        Test.startTest();
        Database.executeBatch(new InactiveFlowCleaner(plan, false, null), 2);
        Test.stopTest();

        List<Flow_Version_Cleaner_Log__c> logs = [
            SELECT Flow_Name__c FROM Flow_Version_Cleaner_Log__c
            WHERE Action__c = 'Teardown'
        ];
        System.assertEquals(4, logs.size(), 'Expected 4 Teardown log entries across 2 definitions');
    }

    // ── Empty teardown plan ───────────────────────────────────────────────────

    @IsTest
    static void testFullTeardown_EmptyPlan() {
        Map<String, List<FlowVersionCleaner.FlowVersion>> plan =
            new Map<String, List<FlowVersionCleaner.FlowVersion>>();
        Test.setMock(HttpCalloutMock.class, new TeardownMock(204));
        Test.startTest();
        Database.executeBatch(new InactiveFlowCleaner(plan, false, null), 1);
        Test.stopTest();
        // No exception = pass
    }

    // ── Empty version list for a definition ───────────────────────────────────

    @IsTest
    static void testFullTeardown_EmptyVersionList() {
        Map<String, List<FlowVersionCleaner.FlowVersion>> plan =
            new Map<String, List<FlowVersionCleaner.FlowVersion>>{
                'DEF1' => new List<FlowVersionCleaner.FlowVersion>()
            };
        Test.setMock(HttpCalloutMock.class, new TeardownMock(204));
        Test.startTest();
        Database.executeBatch(new InactiveFlowCleaner(plan, false, null), 1);
        Test.stopTest();

        List<Flow_Version_Cleaner_Log__c> warnLogs = [
            SELECT Message__c FROM Flow_Version_Cleaner_Log__c WHERE Action__c = 'Warning'
        ];
        System.assertNotEquals(0, warnLogs.size(), 'Warning should be logged for empty version list');
    }

    // ── With jobId ────────────────────────────────────────────────────────────

    @IsTest
    static void testFullTeardown_WithJobId() {
        Map<String, List<FlowVersionCleaner.FlowVersion>> plan = buildPlan('DEF1', 'DeadFlow', 2);
        Test.setMock(HttpCalloutMock.class, new TeardownMock(204));
        Test.startTest();
        Database.executeBatch(new InactiveFlowCleaner(plan, false, '7073x000000abcde'), 1);
        Test.stopTest();

        List<Flow_Version_Cleaner_Log__c> logs = [
            SELECT Batch_Job_Id__c FROM Flow_Version_Cleaner_Log__c
            WHERE Batch_Job_Id__c = '7073x000000abcde'
        ];
        System.assertNotEquals(0, logs.size(), 'Logs should be written with provided jobId');
    }

    // ── queryFlowInterviews — empty list ──────────────────────────────────────

    @IsTest
    static void queryFlowInterviews_handlesEmptyList() {
        InactiveFlowCleaner cleaner = new InactiveFlowCleaner(
            new Map<String, List<FlowVersionCleaner.FlowVersion>>(), false, null);
        Test.startTest();
        List<String> result = cleaner.queryFlowInterviews(new List<String>());
        Test.stopTest();
        System.assertEquals(0, result.size(), 'Empty input should return empty list');
    }

    // ── Log records — all fields populated ───────────────────────────────────

    @IsTest
    static void testLogs_AllFieldsPopulated() {
        Map<String, List<FlowVersionCleaner.FlowVersion>> plan = buildPlan('DEF1', 'MyDeadFlow', 2);
        Test.setMock(HttpCalloutMock.class, new TeardownMock(204));
        Test.startTest();
        Database.executeBatch(new InactiveFlowCleaner(plan, false, 'JOB123'), 1);
        Test.stopTest();

        List<Flow_Version_Cleaner_Log__c> logs = [
            SELECT Flow_Name__c, Version_Number__c, Flow_Status__c,
                   Action__c, Batch__c, Batch_Job_Id__c, Dry_Run__c
            FROM Flow_Version_Cleaner_Log__c
            WHERE Action__c = 'Teardown'
            ORDER BY Version_Number__c ASC
        ];

        System.assertEquals(2, logs.size(), 'Expected 2 Teardown log entries');

        // Verify all fields are populated
        System.assertEquals('MyDeadFlow',       logs[0].Flow_Name__c,    'Flow name');
        System.assertEquals(1,                  logs[0].Version_Number__c,'Version number');
        System.assertEquals('Obsolete',         logs[0].Flow_Status__c,  'Flow status');
        System.assertEquals('Teardown',         logs[0].Action__c,       'Action');
        System.assertEquals('InactiveFlowCleaner', logs[0].Batch__c,     'Batch name');
        System.assertEquals('JOB123',           logs[0].Batch_Job_Id__c, 'Job ID');
        System.assertEquals(false,              logs[0].Dry_Run__c,      'Dry run flag');

        System.assertEquals('MyDeadFlow',       logs[1].Flow_Name__c,    'Flow name v2');
        System.assertEquals(2,                  logs[1].Version_Number__c,'Version number v2');
    }

    // ── Dry run — all log fields populated ────────────────────────────────────

    @IsTest
    static void testDryRunLogs_AllFieldsPopulated() {
        Map<String, List<FlowVersionCleaner.FlowVersion>> plan = buildPlan('DEF1', 'MyDeadFlow', 2);
        Test.setMock(HttpCalloutMock.class, new TeardownMock(204));
        Test.startTest();
        Database.executeBatch(new InactiveFlowCleaner(plan, true, 'JOB456'), 1);
        Test.stopTest();

        List<Flow_Version_Cleaner_Log__c> logs = [
            SELECT Flow_Name__c, Version_Number__c, Flow_Status__c,
                   Action__c, Dry_Run__c, Batch_Job_Id__c
            FROM Flow_Version_Cleaner_Log__c
            WHERE Action__c = 'Dry Run'
            ORDER BY Version_Number__c ASC
        ];

        System.assertEquals(2, logs.size(), 'Expected 2 Dry Run log entries');
        System.assertEquals('MyDeadFlow', logs[0].Flow_Name__c,     'Flow name');
        System.assertEquals(1,            logs[0].Version_Number__c, 'Version number');
        System.assertEquals('Obsolete',   logs[0].Flow_Status__c,   'Flow status');
        System.assertEquals(true,         logs[0].Dry_Run__c,       'Dry run should be true');
        System.assertEquals('JOB456',     logs[0].Batch_Job_Id__c,  'Job ID');
    }
}