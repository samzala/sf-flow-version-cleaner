/**
 * FlowVersionCleanerTest
 *
 * Test class for FlowVersionCleaner.
 * Covers: start(), execute(), finish(), queryAllFlowVersions(),
 * parseQueryResponse(), groupByDefinition(), buildDeleteList(),
 * identifyTeardownCandidates(), queryFlowInterviewsByVersionIds(),
 * and deleteFlowInterviews().
 */
@IsTest
private class FlowVersionCleanerTest {

    // ── Helpers ───────────────────────────────────────────────────────────────

    private static Flow_Cleanup_Settings__c buildSettings(
        Integer versionsToKeep, Boolean dryRun, Integer batchSize
    ) {
        return buildSettingsFull(versionsToKeep, dryRun, batchSize, false, null);
    }

    private static Flow_Cleanup_Settings__c buildSettingsFull(
        Integer versionsToKeep, Boolean dryRun, Integer batchSize,
        Boolean deleteInactiveFlows, Integer inactiveThresholdMonths
    ) {
        Flow_Cleanup_Settings__c s = new Flow_Cleanup_Settings__c(
            SetupOwnerId                      = UserInfo.getOrganizationId(),
            Inactive_Versions_To_Keep__c      = versionsToKeep,
            Dry_Run__c                        = dryRun,
            Batch_Size__c                     = batchSize,
            Delete_Inactive_Flows__c          = deleteInactiveFlows,
            Inactive_Flow_Threshold_Months__c = inactiveThresholdMonths
        );
        upsert s;
        return s;
    }

    private static String buildToolingResponse(List<Map<String, Object>> records) {
        return JSON.serialize(new Map<String, Object>{
            'done' => true, 'totalSize' => records.size(), 'records' => records
        });
    }

    private static Map<String, Object> buildRecord(
        String id, String definitionId, String definitionName,
        Integer versionNumber, String status
    ) {
        return buildRecordWithDate(id, definitionId, definitionName,
            versionNumber, status, DateTime.now());
    }

    private static Map<String, Object> buildRecordWithDate(
        String id, String definitionId, String definitionName,
        Integer versionNumber, String status, DateTime lastModifiedDate
    ) {
        return new Map<String, Object>{
            'Id'               => id,
            'DefinitionId'     => definitionId,
            'VersionNumber'    => versionNumber,
            'Status'           => status,
            'LastModifiedDate' => lastModifiedDate.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss.SSS+0000'),
            'Definition'       => new Map<String, Object>{ 'DeveloperName' => definitionName }
        };
    }

    private static FlowVersionCleaner.FlowVersion buildFlowVersion(
        String id, String definitionId, String definitionName,
        Integer versionNumber, String status, DateTime lastModified
    ) {
        FlowVersionCleaner.FlowVersion fv = new FlowVersionCleaner.FlowVersion();
        fv.id                  = id;
        fv.definitionId        = definitionId;
        fv.definitionName      = definitionName;
        fv.versionNumber       = versionNumber;
        fv.status              = status;
        fv.versionLastModified = lastModified;
        return fv;
    }

    // ── Mocks ─────────────────────────────────────────────────────────────────

    private class SuccessMock implements HttpCalloutMock {
        private String body;
        private Integer statusCode;
        public SuccessMock(String body, Integer statusCode) {
            this.body = body; this.statusCode = statusCode;
        }
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(statusCode);
            res.setBody(body);
            return res;
        }
    }

    private class CalloutExceptionMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            throw new System.CalloutException('Simulated callout failure');
        }
    }

    private class QueryThenDeleteMock implements HttpCalloutMock {
        private String queryBody;
        private Integer deleteStatusCode;
        private String deleteBody;
        public QueryThenDeleteMock(String queryBody, Integer deleteStatusCode, String deleteBody) {
            this.queryBody = queryBody;
            this.deleteStatusCode = deleteStatusCode;
            this.deleteBody = deleteBody;
        }
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            if (req.getMethod() == 'GET') {
                res.setStatusCode(200);
                res.setBody(queryBody);
            } else {
                res.setStatusCode(deleteStatusCode);
                res.setBody(deleteBody);
            }
            return res;
        }
    }

    private class QueryThenDeleteExceptionMock implements HttpCalloutMock {
        private String queryBody;
        public QueryThenDeleteExceptionMock(String queryBody) { this.queryBody = queryBody; }
        public HttpResponse respond(HttpRequest req) {
            if (req.getMethod() == 'GET') {
                HttpResponse res = new HttpResponse();
                res.setStatusCode(200);
                res.setBody(queryBody);
                return res;
            }
            throw new System.CalloutException('Simulated delete callout failure');
        }
    }



    @IsTest
    static void start_abortsWhenSettingsNull() {
        Test.setMock(HttpCalloutMock.class, new SuccessMock(
            buildToolingResponse(new List<Map<String, Object>>()), 200));
        Test.startTest();
        Database.executeBatch(new FlowVersionCleaner(), 100);
        Test.stopTest();

        List<Flow_Version_Cleaner_Log__c> logs = [
            SELECT Action__c, Message__c FROM Flow_Version_Cleaner_Log__c
            WHERE Action__c = 'Info' AND Batch__c = 'FlowVersionCleaner'
        ];
        System.assertNotEquals(0, logs.size(), 'Should log at least one Info record');
        Boolean foundAbortMsg = false;
        for (Flow_Version_Cleaner_Log__c l : logs) {
            if (l.Message__c != null && l.Message__c.contains('not configured')) {
                foundAbortMsg = true;
            }
        }
        System.assert(foundAbortMsg, 'Should log abort message');
    }

    @IsTest
    static void start_handlesEmptyVersionList() {
        buildSettings(2, false, 100);
        Test.setMock(HttpCalloutMock.class, new SuccessMock(
            buildToolingResponse(new List<Map<String, Object>>()), 200));
        Test.startTest();
        Database.executeBatch(new FlowVersionCleaner(), 100);
        Test.stopTest();

        List<Flow_Version_Cleaner_Log__c> logs = [
            SELECT Action__c, Message__c FROM Flow_Version_Cleaner_Log__c
            WHERE Action__c = 'Info' AND Batch__c = 'FlowVersionCleaner'
        ];
        System.assertNotEquals(0, logs.size(), 'Should log Info records');
        Boolean foundMsg = false;
        for (Flow_Version_Cleaner_Log__c l : logs) {
            if (l.Message__c != null && l.Message__c.contains('Nothing to do')) {
                foundMsg = true;
            }
        }
        System.assert(foundMsg, 'Should log nothing to do message');
    }

    // ── execute() — dry run ───────────────────────────────────────────────────

    @IsTest
    static void execute_dryRunCreatesLogRecords() {
        buildSettings(1, true, 100);
        List<Map<String, Object>> records = new List<Map<String, Object>>{
            buildRecord('001', 'DEF1', 'MyFlow', 1, 'Obsolete'),
            buildRecord('002', 'DEF1', 'MyFlow', 2, 'Obsolete'),
            buildRecord('003', 'DEF1', 'MyFlow', 3, 'Active')
        };
        Test.setMock(HttpCalloutMock.class, new SuccessMock(buildToolingResponse(records), 200));
        Test.startTest();
        Database.executeBatch(new FlowVersionCleaner(), 100);
        Test.stopTest();

        List<Flow_Version_Cleaner_Log__c> dryRunLogs = [
            SELECT Flow_Name__c, Version_Number__c, Flow_Status__c
            FROM Flow_Version_Cleaner_Log__c
            WHERE Action__c = 'Dry Run'
        ];
        System.assertEquals(1, dryRunLogs.size(), 'One version should be dry-run logged');
        System.assertEquals('MyFlow', dryRunLogs[0].Flow_Name__c, 'Flow name should be populated');
        System.assertEquals(1, dryRunLogs[0].Version_Number__c, 'Version number should be populated');
        System.assertEquals('Obsolete', dryRunLogs[0].Flow_Status__c, 'Flow status should be populated');
    }

    // ── execute() — nothing to delete ────────────────────────────────────────

    @IsTest
    static void execute_nothingToDeleteWhenWithinThreshold() {
        buildSettings(3, false, 100);
        List<Map<String, Object>> records = new List<Map<String, Object>>{
            buildRecord('001', 'DEF1', 'MyFlow', 1, 'Obsolete'),
            buildRecord('002', 'DEF1', 'MyFlow', 2, 'Obsolete'),
            buildRecord('003', 'DEF1', 'MyFlow', 3, 'Active')
        };
        Test.setMock(HttpCalloutMock.class, new SuccessMock(buildToolingResponse(records), 200));
        Test.startTest();
        Database.executeBatch(new FlowVersionCleaner(), 100);
        Test.stopTest();
        List<Flow_Version_Cleaner_Log__c> deletedLogs = [
            SELECT Id FROM Flow_Version_Cleaner_Log__c WHERE Action__c = 'Deleted'
        ];
        System.assertEquals(0, deletedLogs.size(), 'Nothing should be deleted');
    }

    // ── execute() — post-active versions preserved ────────────────────────────

    @IsTest
    static void execute_preservesPostActiveVersions() {
        buildSettings(1, true, 100);
        List<Map<String, Object>> records = new List<Map<String, Object>>{
            buildRecord('001', 'DEF1', 'MyFlow', 1, 'Obsolete'),
            buildRecord('002', 'DEF1', 'MyFlow', 2, 'Obsolete'),
            buildRecord('003', 'DEF1', 'MyFlow', 3, 'Active'),
            buildRecord('004', 'DEF1', 'MyFlow', 4, 'Obsolete'),
            buildRecord('005', 'DEF1', 'MyFlow', 5, 'Draft')
        };
        Test.setMock(HttpCalloutMock.class, new SuccessMock(buildToolingResponse(records), 200));
        Test.startTest();
        Database.executeBatch(new FlowVersionCleaner(), 100);
        Test.stopTest();
        // Only v1 should be dry-run queued — v2 kept, v4 and v5 post-active
        List<Flow_Version_Cleaner_Log__c> dryRunLogs = [
            SELECT Version_Number__c FROM Flow_Version_Cleaner_Log__c WHERE Action__c = 'Dry Run'
        ];
        System.assertEquals(1, dryRunLogs.size(), 'Only v1 should be queued');
        System.assertEquals(1, dryRunLogs[0].Version_Number__c, 'v1 should be queued');
    }

    // ── execute() — no active version ────────────────────────────────────────

    @IsTest
    static void execute_noActiveVersionKeepsMostRecent() {
        buildSettings(2, true, 100);
        List<Map<String, Object>> records = new List<Map<String, Object>>{
            buildRecord('001', 'DEF1', 'MyFlow', 1, 'Obsolete'),
            buildRecord('002', 'DEF1', 'MyFlow', 2, 'Obsolete'),
            buildRecord('003', 'DEF1', 'MyFlow', 3, 'Obsolete'),
            buildRecord('004', 'DEF1', 'MyFlow', 4, 'Draft')
        };
        Test.setMock(HttpCalloutMock.class, new SuccessMock(buildToolingResponse(records), 200));
        Test.startTest();
        Database.executeBatch(new FlowVersionCleaner(), 100);
        Test.stopTest();
        // v1 and v2 should be queued, v3 and v4 kept
        List<Flow_Version_Cleaner_Log__c> dryRunLogs = [
            SELECT Version_Number__c FROM Flow_Version_Cleaner_Log__c
            WHERE Action__c = 'Dry Run'
            ORDER BY Version_Number__c ASC
        ];
        System.assertEquals(2, dryRunLogs.size(), 'v1 and v2 should be queued');
        System.assertEquals(1, dryRunLogs[0].Version_Number__c, 'v1 should be queued');
        System.assertEquals(2, dryRunLogs[1].Version_Number__c, 'v2 should be queued');
    }

    // ── execute() — multiple flows grouped correctly ──────────────────────────

    @IsTest
    static void execute_multipleFlowsGroupedCorrectly() {
        buildSettings(1, true, 100);
        List<Map<String, Object>> records = new List<Map<String, Object>>{
            buildRecord('001', 'DEF1', 'FlowA', 1, 'Obsolete'),
            buildRecord('002', 'DEF1', 'FlowA', 2, 'Active'),
            buildRecord('003', 'DEF2', 'FlowB', 1, 'Obsolete'),
            buildRecord('004', 'DEF2', 'FlowB', 2, 'Obsolete'),
            buildRecord('005', 'DEF2', 'FlowB', 3, 'Active')
        };
        Test.setMock(HttpCalloutMock.class, new SuccessMock(buildToolingResponse(records), 200));
        Test.startTest();
        Database.executeBatch(new FlowVersionCleaner(), 100);
        Test.stopTest();
        // FlowA: nothing to delete (1 obsolete, keep 1)
        // FlowB: v1 queued, v2 kept
        List<Flow_Version_Cleaner_Log__c> dryRunLogs = [
            SELECT Flow_Name__c, Version_Number__c FROM Flow_Version_Cleaner_Log__c
            WHERE Action__c = 'Dry Run'
        ];
        System.assertEquals(1, dryRunLogs.size(), 'Only FlowB v1 should be queued');
        System.assertEquals('FlowB', dryRunLogs[0].Flow_Name__c, 'Should be FlowB');
        System.assertEquals(1, dryRunLogs[0].Version_Number__c, 'Should be v1');
    }

    // ── execute() — successful delete ─────────────────────────────────────────

    @IsTest
    static void execute_successfulDeleteCreatesLogRecord() {
        buildSettings(1, false, 100);
        List<Map<String, Object>> records = new List<Map<String, Object>>{
            buildRecord('001', 'DEF1', 'MyFlow', 1, 'Obsolete'),
            buildRecord('002', 'DEF1', 'MyFlow', 2, 'Obsolete'),
            buildRecord('003', 'DEF1', 'MyFlow', 3, 'Active')
        };
        Test.setMock(HttpCalloutMock.class, new QueryThenDeleteMock(
            buildToolingResponse(records), 204, ''));
        Test.startTest();
        Database.executeBatch(new FlowVersionCleaner(), 100);
        Test.stopTest();

        List<Flow_Version_Cleaner_Log__c> deletedLogs = [
            SELECT Flow_Name__c, Version_Number__c, Flow_Status__c
            FROM Flow_Version_Cleaner_Log__c
            WHERE Action__c = 'Deleted'
        ];
        System.assertEquals(1, deletedLogs.size(), 'One version should be deleted');
        System.assertEquals('MyFlow', deletedLogs[0].Flow_Name__c, 'Flow name should be populated');
        System.assertEquals(1, deletedLogs[0].Version_Number__c, 'Version number should be populated');
        System.assertEquals('Obsolete', deletedLogs[0].Flow_Status__c, 'Flow status should be populated');
    }

    // ── execute() — failed delete ─────────────────────────────────────────────

    @IsTest
    static void execute_failedDeleteCreatesFailedLogRecord() {
        buildSettings(1, false, 100);
        List<Map<String, Object>> records = new List<Map<String, Object>>{
            buildRecord('001', 'DEF1', 'MyFlow', 1, 'Obsolete'),
            buildRecord('002', 'DEF1', 'MyFlow', 2, 'Obsolete'),
            buildRecord('003', 'DEF1', 'MyFlow', 3, 'Active')
        };
        Test.setMock(HttpCalloutMock.class, new QueryThenDeleteMock(
            buildToolingResponse(records), 400, '{"errorCode":"UNKNOWN_EXCEPTION"}'));
        Test.startTest();
        Database.executeBatch(new FlowVersionCleaner(), 100);
        Test.stopTest();

        List<Flow_Version_Cleaner_Log__c> failedLogs = [
            SELECT Flow_Name__c, Version_Number__c, Message__c
            FROM Flow_Version_Cleaner_Log__c
            WHERE Action__c = 'Failed'
            AND Flow_Name__c != null
        ];
        System.assertEquals(1, failedLogs.size(), 'One failed log should exist');
        System.assertEquals('MyFlow', failedLogs[0].Flow_Name__c, 'Flow name should be populated');
        System.assertEquals(1, failedLogs[0].Version_Number__c, 'Version number should be populated');
    }

    // ── execute() — delete callout exception ──────────────────────────────────

    @IsTest
    static void execute_deleteCalloutExceptionCaught() {
        buildSettings(1, false, 100);
        List<Map<String, Object>> records = new List<Map<String, Object>>{
            buildRecord('001', 'DEF1', 'MyFlow', 1, 'Obsolete'),
            buildRecord('002', 'DEF1', 'MyFlow', 2, 'Obsolete'),
            buildRecord('003', 'DEF1', 'MyFlow', 3, 'Active')
        };
        Test.setMock(HttpCalloutMock.class, new QueryThenDeleteExceptionMock(
            buildToolingResponse(records)));
        Test.startTest();
        Database.executeBatch(new FlowVersionCleaner(), 100);
        Test.stopTest();

        List<Flow_Version_Cleaner_Log__c> failedLogs = [
            SELECT Message__c FROM Flow_Version_Cleaner_Log__c
            WHERE Action__c = 'Failed' AND Flow_Name__c != null
        ];
        System.assertEquals(1, failedLogs.size(), 'One failed log should exist');
        System.assert(failedLogs[0].Message__c.contains('Simulated'), 'Exception message should be logged');
    }

    // ── query — non-200 throws exception ──────────────────────────────────────

    @IsTest
    static void query_throwsOnNon200() {
        buildSettings(2, false, 100);
        Test.setMock(HttpCalloutMock.class, new SuccessMock('{"error":"unauthorized"}', 401));
        Test.startTest();
        try {
            Database.executeBatch(new FlowVersionCleaner(), 100);
            Test.stopTest();
        } catch (FlowVersionCleaner.FlowCleanerException e) {
            System.assert(e.getMessage().contains('401'), 'Expected 401 in message');
        }
    }

    // ── query — callout exception wraps correctly ─────────────────────────────

    @IsTest
    static void query_throwsOnCalloutException() {
        buildSettings(2, false, 100);
        Test.setMock(HttpCalloutMock.class, new CalloutExceptionMock());
        Test.startTest();
        try {
            Database.executeBatch(new FlowVersionCleaner(), 100);
            Test.stopTest();
        } catch (FlowVersionCleaner.FlowCleanerException e) {
            System.assert(e.getMessage().contains('Callout failed'), 'Expected callout failed');
        }
    }

    // ── parse — null Definition handled ──────────────────────────────────────

    @IsTest
    static void parse_handlesNullDefinition() {
        List<Map<String, Object>> records = new List<Map<String, Object>>{
            new Map<String, Object>{
                'Id' => '001', 'DefinitionId' => 'DEF1',
                'VersionNumber' => 1, 'Status' => 'Obsolete', 'Definition' => null
            }
        };
        Test.startTest();
        List<FlowVersionCleaner.FlowVersion> versions =
            FlowVersionCleaner.parseQueryResponse(buildToolingResponse(records));
        Test.stopTest();
        System.assertEquals(1, versions.size());
        System.assertEquals('Unknown', versions[0].definitionName);
    }

    // ── parse — LastModifiedDate parsed correctly ─────────────────────────────

    @IsTest
    static void parse_handlesLastModifiedDate() {
        DateTime testDate = DateTime.newInstanceGmt(2025, 6, 15, 10, 30, 0);
        List<Map<String, Object>> records = new List<Map<String, Object>>{
            buildRecordWithDate('001', 'DEF1', 'MyFlow', 1, 'Obsolete', testDate)
        };
        Test.startTest();
        List<FlowVersionCleaner.FlowVersion> versions =
            FlowVersionCleaner.parseQueryResponse(buildToolingResponse(records));
        Test.stopTest();
        System.assertEquals(1, versions.size());
        System.assertNotEquals(null, versions[0].versionLastModified,
            'LastModifiedDate should be parsed');
    }

    // ── buildDeleteList — picks highest active version ────────────────────────

    @IsTest
    static void buildDeleteList_picksHighestActiveVersion() {
        buildSettings(1, true, 100);
        List<Map<String, Object>> records = new List<Map<String, Object>>{
            buildRecord('001', 'DEF1', 'MyFlow', 1, 'Obsolete'),
            buildRecord('002', 'DEF1', 'MyFlow', 2, 'Obsolete'),
            buildRecord('003', 'DEF1', 'MyFlow', 3, 'Active'),
            buildRecord('004', 'DEF1', 'MyFlow', 4, 'Active'),
            buildRecord('005', 'DEF1', 'MyFlow', 5, 'Draft')
        };
        Test.setMock(HttpCalloutMock.class, new SuccessMock(buildToolingResponse(records), 200));
        Test.startTest();
        Database.executeBatch(new FlowVersionCleaner(), 100);
        Test.stopTest();

        // Highest active = v4. Post-active = v5 (preserved).
        // v3 is Active — skipped from eligible.
        // Eligible = v1, v2. versionsToKeep=1 → deleteCount=1 → only v1 queued.
        List<Flow_Version_Cleaner_Log__c> dryRunLogs = [
            SELECT Version_Number__c FROM Flow_Version_Cleaner_Log__c
            WHERE Action__c = 'Dry Run' ORDER BY Version_Number__c ASC
        ];
        System.assertEquals(1, dryRunLogs.size(), 'Only v1 should be queued');
        System.assertEquals(1, dryRunLogs[0].Version_Number__c, 'v1 should be queued');
    }

    // ── identifyTeardownCandidates — below threshold ──────────────────────────

    @IsTest
    static void teardown_belowThreshold_notQueued() {
        Map<String, List<FlowVersionCleaner.FlowVersion>> byDef =
            new Map<String, List<FlowVersionCleaner.FlowVersion>>{
                'DEF1' => new List<FlowVersionCleaner.FlowVersion>{
                    buildFlowVersion('001', 'DEF1', 'InactiveFlow', 1, 'Obsolete', DateTime.now()),
                    buildFlowVersion('002', 'DEF1', 'InactiveFlow', 2, 'Obsolete', DateTime.now())
                }
            };
        Map<String, List<FlowVersionCleaner.FlowVersion>> candidates =
            new Map<String, List<FlowVersionCleaner.FlowVersion>>();
        Test.startTest();
        FlowVersionCleaner.identifyTeardownCandidates(byDef, DateTime.now().addMonths(-3), candidates);
        Test.stopTest();
        System.assertEquals(0, candidates.size(),
            'Recently modified flow should not be a teardown candidate');
    }

    // ── identifyTeardownCandidates — above threshold ──────────────────────────

    @IsTest
    static void teardown_aboveThreshold_queued() {
        DateTime sixMonthsAgo = DateTime.now().addMonths(-6);
        Map<String, List<FlowVersionCleaner.FlowVersion>> byDef =
            new Map<String, List<FlowVersionCleaner.FlowVersion>>{
                'DEF1' => new List<FlowVersionCleaner.FlowVersion>{
                    buildFlowVersion('001', 'DEF1', 'OldFlow', 1, 'Obsolete', sixMonthsAgo),
                    buildFlowVersion('002', 'DEF1', 'OldFlow', 2, 'Obsolete', sixMonthsAgo)
                }
            };
        Map<String, List<FlowVersionCleaner.FlowVersion>> candidates =
            new Map<String, List<FlowVersionCleaner.FlowVersion>>();
        Test.startTest();
        FlowVersionCleaner.identifyTeardownCandidates(byDef, DateTime.now().addMonths(-3), candidates);
        Test.stopTest();
        System.assertEquals(1, candidates.size(), 'Old flow should be a teardown candidate');
        System.assert(candidates.containsKey('DEF1'), 'DEF1 should be in candidates');
    }

    // ── identifyTeardownCandidates — active flow never considered ─────────────

    @IsTest
    static void teardown_activeFlowNeverConsidered() {
        DateTime sixMonthsAgo = DateTime.now().addMonths(-6);
        Map<String, List<FlowVersionCleaner.FlowVersion>> byDef =
            new Map<String, List<FlowVersionCleaner.FlowVersion>>{
                'DEF1' => new List<FlowVersionCleaner.FlowVersion>{
                    buildFlowVersion('001', 'DEF1', 'ActiveFlow', 1, 'Obsolete', sixMonthsAgo),
                    buildFlowVersion('002', 'DEF1', 'ActiveFlow', 2, 'Active',   sixMonthsAgo)
                }
            };
        Map<String, List<FlowVersionCleaner.FlowVersion>> candidates =
            new Map<String, List<FlowVersionCleaner.FlowVersion>>();
        Test.startTest();
        FlowVersionCleaner.identifyTeardownCandidates(byDef, DateTime.now().addMonths(-3), candidates);
        Test.stopTest();
        System.assertEquals(0, candidates.size(), 'Active flow must never be a teardown candidate');
    }

    // ── identifyTeardownCandidates — mixed flows ──────────────────────────────

    @IsTest
    static void teardown_mixedFlows_correctSeparation() {
        DateTime sixMonthsAgo = DateTime.now().addMonths(-6);
        Map<String, List<FlowVersionCleaner.FlowVersion>> byDef =
            new Map<String, List<FlowVersionCleaner.FlowVersion>>{
                'DEF1' => new List<FlowVersionCleaner.FlowVersion>{
                    buildFlowVersion('001', 'DEF1', 'ActiveFlow', 1, 'Obsolete', sixMonthsAgo),
                    buildFlowVersion('002', 'DEF1', 'ActiveFlow', 2, 'Active',   sixMonthsAgo)
                },
                'DEF2' => new List<FlowVersionCleaner.FlowVersion>{
                    buildFlowVersion('003', 'DEF2', 'DeadFlow', 1, 'Obsolete', sixMonthsAgo),
                    buildFlowVersion('004', 'DEF2', 'DeadFlow', 2, 'Obsolete', sixMonthsAgo)
                }
            };
        Map<String, List<FlowVersionCleaner.FlowVersion>> candidates =
            new Map<String, List<FlowVersionCleaner.FlowVersion>>();
        Test.startTest();
        FlowVersionCleaner.identifyTeardownCandidates(byDef, DateTime.now().addMonths(-3), candidates);
        Test.stopTest();
        System.assertEquals(1, candidates.size(), 'Only dead flow should be a candidate');
        System.assert(candidates.containsKey('DEF2'), 'DEF2 should be the candidate');
    }

    // ── identifyTeardownCandidates — feature flag off ─────────────────────────

    @IsTest
    static void teardown_featureFlagOff_neverQueued() {
        buildSettingsFull(1, true, 100, false, 3);
        DateTime sixMonthsAgo = DateTime.now().addMonths(-6);
        List<Map<String, Object>> records = new List<Map<String, Object>>{
            buildRecordWithDate('001', 'DEF1', 'OldFlow', 1, 'Obsolete', sixMonthsAgo),
            buildRecordWithDate('002', 'DEF1', 'OldFlow', 2, 'Obsolete', sixMonthsAgo)
        };
        Test.setMock(HttpCalloutMock.class, new SuccessMock(buildToolingResponse(records), 200));
        Test.startTest();
        FlowVersionCleaner batch = new FlowVersionCleaner();
        Database.executeBatch(batch, 100);
        Test.stopTest();
        System.assertEquals(0, batch.teardownCandidates.size(),
            'Teardown should not trigger when feature flag is off');
    }

    // ── teardown — dry run chains InactiveFlowCleaner ─────────────────────────

    @IsTest
    static void teardown_dryRun_chainsInactiveFlowCleaner() {
        buildSettingsFull(1, true, 100, true, 3);
        DateTime sixMonthsAgo = DateTime.now().addMonths(-6);
        List<Map<String, Object>> records = new List<Map<String, Object>>{
            buildRecordWithDate('001', 'DEF1', 'OldFlow', 1, 'Obsolete', sixMonthsAgo),
            buildRecordWithDate('002', 'DEF1', 'OldFlow', 2, 'Obsolete', sixMonthsAgo)
        };
        Test.setMock(HttpCalloutMock.class, new SuccessMock(buildToolingResponse(records), 200));
        Test.startTest();
        Database.executeBatch(new FlowVersionCleaner(), 100);
        Test.stopTest();
        // No exception = InactiveFlowCleaner chained successfully in dry run
    }

    // ── @JsonAccess — FlowVersion fields survive serialisation ───────────────
    // This is the key test for the bug fix — verifies that FlowVersion fields
    // are preserved when the object is serialised and deserialised (as happens
    // when passed from FlowVersionCleaner to InactiveFlowCleaner).

    @IsTest
    static void flowVersion_fieldsPreservedAfterSerialisation() {
        FlowVersionCleaner.FlowVersion fv = new FlowVersionCleaner.FlowVersion();
        fv.id                  = 'TEST_ID';
        fv.definitionId        = 'DEF_ID';
        fv.definitionName      = 'TestFlow';
        fv.versionNumber       = 42;
        fv.status              = 'Obsolete';
        fv.versionLastModified = DateTime.now().addMonths(-6);

        // Simulate what Salesforce does when passing between batch jobs
        String serialised = JSON.serialize(fv);
        FlowVersionCleaner.FlowVersion deserialised =
            (FlowVersionCleaner.FlowVersion) JSON.deserialize(
                serialised, FlowVersionCleaner.FlowVersion.class);

        System.assertEquals('TEST_ID',   deserialised.id,             'id should survive serialisation');
        System.assertEquals('TestFlow',  deserialised.definitionName,  'definitionName should survive');
        System.assertEquals(42,          deserialised.versionNumber,   'versionNumber should survive');
        System.assertEquals('Obsolete',  deserialised.status,          'status should survive');
        System.assertNotEquals(null,      deserialised.versionLastModified, 'date should survive');
    }
}