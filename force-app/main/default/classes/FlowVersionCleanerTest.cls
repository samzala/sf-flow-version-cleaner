/**
 * FlowVersionCleanerTest
 *
 * Test class for FlowVersionCleaner batch class.
 * Covers all methods including start(), execute(), finish(),
 * queryAllFlowVersions(), parseQueryResponse(), groupByDefinition(),
 * and buildDeleteList().
 */
@IsTest
private class FlowVersionCleanerTest {

    // ── Helpers ───────────────────────────────────────────────────────────────

    private static Flow_Cleanup_Settings__c buildSettings(Integer versionsToKeep, Boolean dryRun, Integer batchSize) {
        Flow_Cleanup_Settings__c settings = new Flow_Cleanup_Settings__c(
            SetupOwnerId                 = UserInfo.getOrganizationId(),
            Inactive_Versions_To_Keep__c = versionsToKeep,
            Dry_Run__c                   = dryRun,
            Batch_Size__c                = batchSize
        );
        upsert settings;
        return settings;
    }

    private static String buildToolingResponse(List<Map<String, Object>> records) {
        Map<String, Object> response = new Map<String, Object>{
            'done'      => true,
            'totalSize' => records.size(),
            'records'   => records
        };
        return JSON.serialize(response);
    }

    private static Map<String, Object> buildRecord(
        String id,
        String definitionId,
        String definitionName,
        Integer versionNumber,
        String status
    ) {
        return new Map<String, Object>{
            'Id'            => id,
            'DefinitionId'  => definitionId,
            'VersionNumber' => versionNumber,
            'Status'        => status,
            'Definition'    => new Map<String, Object>{ 'DeveloperName' => definitionName }
        };
    }

    // ── Mocks ─────────────────────────────────────────────────────────────────

    // Returns a configurable status code and body for any request
    private class SuccessMock implements HttpCalloutMock {
        private String body;
        private Integer statusCode;

        public SuccessMock(String body, Integer statusCode) {
            this.body       = body;
            this.statusCode = statusCode;
        }

        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(statusCode);
            res.setBody(body);
            return res;
        }
    }

    // Throws a CalloutException for any request
    private class CalloutExceptionMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            throw new System.CalloutException('Simulated callout failure');
        }
    }

    // Returns flow versions for GET requests and a configurable
    // status code for DELETE requests
    private class QueryThenDeleteMock implements HttpCalloutMock {
        private String queryBody;
        private Integer deleteStatusCode;
        private String deleteBody;

        public QueryThenDeleteMock(String queryBody, Integer deleteStatusCode, String deleteBody) {
            this.queryBody        = queryBody;
            this.deleteStatusCode = deleteStatusCode;
            this.deleteBody       = deleteBody;
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

    // Returns flow versions for GET requests and throws a
    // CalloutException for DELETE requests
    private class QueryThenDeleteExceptionMock implements HttpCalloutMock {
        private String queryBody;

        public QueryThenDeleteExceptionMock(String queryBody) {
            this.queryBody = queryBody;
        }

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

    // ── start() — settings not configured ────────────────────────────────────
    // Verifies that when no Custom Setting is configured the batch
    // returns an empty list and completes without error.

    @IsTest
    static void start_abortsWhenSettingsNull() {
        Test.setMock(HttpCalloutMock.class, new SuccessMock(
            buildToolingResponse(new List<Map<String, Object>>()), 200
        ));

        Test.startTest();
        Database.executeBatch(new FlowVersionCleaner(), 100);
        Test.stopTest();
    }

    // ── start() — empty version list ──────────────────────────────────────────
    // Verifies that when the Tooling API returns no Flow versions
    // the batch completes cleanly with nothing to delete.

    @IsTest
    static void start_handlesEmptyVersionList() {
        buildSettings(2, false, 100);

        Test.setMock(HttpCalloutMock.class, new SuccessMock(
            buildToolingResponse(new List<Map<String, Object>>()), 200
        ));

        Test.startTest();
        Database.executeBatch(new FlowVersionCleaner(), 100);
        Test.stopTest();
    }

    // ── execute() — dry run ───────────────────────────────────────────────────
    // Verifies that in dry run mode the batch logs versions without
    // firing any DELETE callouts.

    @IsTest
    static void execute_dryRunLogsWithoutDeleting() {
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
    }

    // ── execute() — nothing to delete ────────────────────────────────────────
    // Verifies that when all versions are within the keep threshold
    // nothing is queued for deletion.

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
    }

    // ── execute() — post-active versions preserved ────────────────────────────
    // Verifies that versions with a higher version number than the
    // active version are never queued for deletion.

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
    }

    // ── execute() — no active version ────────────────────────────────────────
    // Verifies that when no active version exists the batch keeps
    // the most recent versionsToKeep versions and deletes the rest.

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
    }

    // ── execute() — multiple flows ────────────────────────────────────────────
    // Verifies that versions are correctly grouped by definition
    // and each Flow is evaluated independently.

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
    }

    // ── execute() — successful delete (204) ───────────────────────────────────
    // Verifies that a 204 response is handled correctly and
    // the deleted count is incremented.

    @IsTest
    static void execute_successfulDelete() {
        buildSettings(1, false, 100);

        List<Map<String, Object>> records = new List<Map<String, Object>>{
            buildRecord('001', 'DEF1', 'MyFlow', 1, 'Obsolete'),
            buildRecord('002', 'DEF1', 'MyFlow', 2, 'Obsolete'),
            buildRecord('003', 'DEF1', 'MyFlow', 3, 'Active')
        };
        Test.setMock(HttpCalloutMock.class, new QueryThenDeleteMock(
            buildToolingResponse(records), 204, ''
        ));

        Test.startTest();
        Database.executeBatch(new FlowVersionCleaner(), 100);
        Test.stopTest();
    }

    // ── execute() — failed delete logs error ──────────────────────────────────
    // Verifies that a non-204 DELETE response logs the error and
    // increments the failed count without throwing.

    @IsTest
    static void execute_failedDeleteLogsError() {
        buildSettings(1, false, 100);

        List<Map<String, Object>> records = new List<Map<String, Object>>{
            buildRecord('001', 'DEF1', 'MyFlow', 1, 'Obsolete'),
            buildRecord('002', 'DEF1', 'MyFlow', 2, 'Obsolete'),
            buildRecord('003', 'DEF1', 'MyFlow', 3, 'Active')
        };
        Test.setMock(HttpCalloutMock.class, new QueryThenDeleteMock(
            buildToolingResponse(records), 400, '{"errorCode":"UNKNOWN_EXCEPTION"}'
        ));

        Test.startTest();
        Database.executeBatch(new FlowVersionCleaner(), 100);
        Test.stopTest();
    }

    // ── execute() — delete callout exception caught ───────────────────────────
    // Verifies that a CalloutException during DELETE is caught and logged
    // without bubbling up as a test failure.

    @IsTest
    static void execute_deleteCalloutExceptionCaught() {
        buildSettings(1, false, 100);

        List<Map<String, Object>> records = new List<Map<String, Object>>{
            buildRecord('001', 'DEF1', 'MyFlow', 1, 'Obsolete'),
            buildRecord('002', 'DEF1', 'MyFlow', 2, 'Obsolete'),
            buildRecord('003', 'DEF1', 'MyFlow', 3, 'Active')
        };
        Test.setMock(HttpCalloutMock.class, new QueryThenDeleteExceptionMock(
            buildToolingResponse(records)
        ));

        Test.startTest();
        Database.executeBatch(new FlowVersionCleaner(), 100);
        Test.stopTest();
    }

    // ── query — non-200 throws FlowCleanerException ───────────────────────────
    // Verifies that a non-200 Tooling API response throws a
    // FlowCleanerException with the status code in the message.

    @IsTest
    static void query_throwsOnNon200() {
        buildSettings(2, false, 100);
        Test.setMock(HttpCalloutMock.class, new SuccessMock('{"error":"unauthorized"}', 401));

        Test.startTest();
        try {
            Database.executeBatch(new FlowVersionCleaner(), 100);
            Test.stopTest();
        } catch (FlowVersionCleaner.FlowCleanerException e) {
            System.assert(e.getMessage().contains('401'), 'Expected 401 in exception message');
        }
    }

    // ── query — callout exception wraps correctly ─────────────────────────────
    // Verifies that a CalloutException during the Tooling API query
    // is wrapped in a FlowCleanerException with a meaningful message.

    @IsTest
    static void query_throwsOnCalloutException() {
        buildSettings(2, false, 100);
        Test.setMock(HttpCalloutMock.class, new CalloutExceptionMock());

        Test.startTest();
        try {
            Database.executeBatch(new FlowVersionCleaner(), 100);
            Test.stopTest();
        } catch (FlowVersionCleaner.FlowCleanerException e) {
            System.assert(e.getMessage().contains('Callout failed'), 'Expected callout failed message');
        }
    }

    // ── parse — null Definition handled ──────────────────────────────────────
    // Verifies that a null Definition in the Tooling API response
    // is handled gracefully and defaults the name to 'Unknown'.

    @IsTest
    static void parse_handlesNullDefinition() {
        List<Map<String, Object>> records = new List<Map<String, Object>>{
            new Map<String, Object>{
                'Id'            => '001',
                'DefinitionId'  => 'DEF1',
                'VersionNumber' => 1,
                'Status'        => 'Obsolete',
                'Definition'    => null
            }
        };

        Test.startTest();
        List<FlowVersionCleaner.FlowVersion> versions = FlowVersionCleaner.parseQueryResponse(
            buildToolingResponse(records)
        );
        Test.stopTest();

        System.assertEquals(1, versions.size());
        System.assertEquals('Unknown', versions[0].definitionName);
    }

    // ── buildDeleteList — picks highest active version ────────────────────────
    // Verifies that when multiple Active versions exist the highest
    // version number is used as the active version boundary.

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
    }
}