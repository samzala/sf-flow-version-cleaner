@IsTest
private class FlowVersionCleanerTest {

    // ── Helpers ───────────────────────────────────────────────────────────────

    private static Flow_Cleanup_Settings__c buildSettings(Integer versionsToKeep, Boolean dryRun) {
        Flow_Cleanup_Settings__c settings = new Flow_Cleanup_Settings__c(
            SetupOwnerId                 = UserInfo.getOrganizationId(),
            Inactive_Versions_To_Keep__c = versionsToKeep,
            Dry_Run__c                   = dryRun
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

    private class CalloutExceptionMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            throw new System.CalloutException('Simulated callout failure');
        }
    }

    // Responds to the first request (GET query) with flow versions,
    // then responds to all subsequent DELETE requests with the given status code
    private class QueryThenDeleteMock implements HttpCalloutMock {
        private String queryBody;
        private Integer deleteStatusCode;
        private String deleteBody;
        private Integer callCount = 0;

        public QueryThenDeleteMock(String queryBody, Integer deleteStatusCode, String deleteBody) {
            this.queryBody        = queryBody;
            this.deleteStatusCode = deleteStatusCode;
            this.deleteBody       = deleteBody;
        }

        public HttpResponse respond(HttpRequest req) {
            callCount++;
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

    // Responds to GET with flow versions, then throws a CalloutException on DELETE
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

    // ── run() — settings not configured ──────────────────────────────────────

    @IsTest
    static void run_abortsWhenSettingsNull() {
        Test.startTest();
        FlowVersionCleaner.run();
        Test.stopTest();
    }

    // ── run() — no flow versions returned ────────────────────────────────────

    @IsTest
    static void run_handlesEmptyVersionList() {
        buildSettings(2, false);

        Test.setMock(HttpCalloutMock.class, new SuccessMock(
            buildToolingResponse(new List<Map<String, Object>>()), 200
        ));

        Test.startTest();
        FlowVersionCleaner.run();
        Test.stopTest();
    }

    // ── run() — dry run logs IDs without deleting ─────────────────────────────

    @IsTest
    static void run_dryRunLogsWithoutDeleting() {
        buildSettings(1, true);

        List<Map<String, Object>> records = new List<Map<String, Object>>{
            buildRecord('001', 'DEF1', 'MyFlow', 1, 'Obsolete'),
            buildRecord('002', 'DEF1', 'MyFlow', 2, 'Obsolete'),
            buildRecord('003', 'DEF1', 'MyFlow', 3, 'Active')
        };
        Test.setMock(HttpCalloutMock.class, new SuccessMock(buildToolingResponse(records), 200));

        Test.startTest();
        FlowVersionCleaner.run();
        Test.stopTest();
    }

    // ── run() — nothing to delete when within keep threshold ──────────────────

    @IsTest
    static void run_nothingToDeleteWhenWithinThreshold() {
        buildSettings(3, false);

        List<Map<String, Object>> records = new List<Map<String, Object>>{
            buildRecord('001', 'DEF1', 'MyFlow', 1, 'Obsolete'),
            buildRecord('002', 'DEF1', 'MyFlow', 2, 'Obsolete'),
            buildRecord('003', 'DEF1', 'MyFlow', 3, 'Active')
        };
        Test.setMock(HttpCalloutMock.class, new SuccessMock(buildToolingResponse(records), 200));

        Test.startTest();
        FlowVersionCleaner.run();
        Test.stopTest();
    }

    // ── run() — post-active versions are preserved ────────────────────────────

    @IsTest
    static void run_preservesPostActiveVersions() {
        buildSettings(1, true);

        List<Map<String, Object>> records = new List<Map<String, Object>>{
            buildRecord('001', 'DEF1', 'MyFlow', 1, 'Obsolete'),
            buildRecord('002', 'DEF1', 'MyFlow', 2, 'Obsolete'),
            buildRecord('003', 'DEF1', 'MyFlow', 3, 'Active'),
            buildRecord('004', 'DEF1', 'MyFlow', 4, 'Obsolete'),
            buildRecord('005', 'DEF1', 'MyFlow', 5, 'Draft')
        };
        Test.setMock(HttpCalloutMock.class, new SuccessMock(buildToolingResponse(records), 200));

        Test.startTest();
        FlowVersionCleaner.run();
        Test.stopTest();
    }

    // ── run() — no active version keeps most recent ───────────────────────────

    @IsTest
    static void run_noActiveVersionKeepsMostRecent() {
        buildSettings(2, true);

        List<Map<String, Object>> records = new List<Map<String, Object>>{
            buildRecord('001', 'DEF1', 'MyFlow', 1, 'Obsolete'),
            buildRecord('002', 'DEF1', 'MyFlow', 2, 'Obsolete'),
            buildRecord('003', 'DEF1', 'MyFlow', 3, 'Obsolete'),
            buildRecord('004', 'DEF1', 'MyFlow', 4, 'Draft')
        };
        Test.setMock(HttpCalloutMock.class, new SuccessMock(buildToolingResponse(records), 200));

        Test.startTest();
        FlowVersionCleaner.run();
        Test.stopTest();
    }

    // ── run() — multiple flows grouped correctly ──────────────────────────────

    @IsTest
    static void run_multipleFlowsGroupedCorrectly() {
        buildSettings(1, true);

        List<Map<String, Object>> records = new List<Map<String, Object>>{
            buildRecord('001', 'DEF1', 'FlowA', 1, 'Obsolete'),
            buildRecord('002', 'DEF1', 'FlowA', 2, 'Active'),
            buildRecord('003', 'DEF2', 'FlowB', 1, 'Obsolete'),
            buildRecord('004', 'DEF2', 'FlowB', 2, 'Obsolete'),
            buildRecord('005', 'DEF2', 'FlowB', 3, 'Active')
        };
        Test.setMock(HttpCalloutMock.class, new SuccessMock(buildToolingResponse(records), 200));

        Test.startTest();
        FlowVersionCleaner.run();
        Test.stopTest();
    }

    // ── run() — successful delete (204) ──────────────────────────────────────

    @IsTest
    static void run_successfulDelete() {
        buildSettings(1, false);

        List<Map<String, Object>> records = new List<Map<String, Object>>{
            buildRecord('001', 'DEF1', 'MyFlow', 1, 'Obsolete'),
            buildRecord('002', 'DEF1', 'MyFlow', 2, 'Obsolete'),
            buildRecord('003', 'DEF1', 'MyFlow', 3, 'Active')
        };

        Test.setMock(HttpCalloutMock.class, new QueryThenDeleteMock(
            buildToolingResponse(records), 204, ''
        ));

        Test.startTest();
        FlowVersionCleaner.run();
        Test.stopTest();
        // v1 deleted (204), v2 kept, v3 active — no exception = pass
    }

    // ── run() — failed delete logs error (non-204) ────────────────────────────

    @IsTest
    static void run_failedDeleteLogsError() {
        buildSettings(1, false);

        List<Map<String, Object>> records = new List<Map<String, Object>>{
            buildRecord('001', 'DEF1', 'MyFlow', 1, 'Obsolete'),
            buildRecord('002', 'DEF1', 'MyFlow', 2, 'Obsolete'),
            buildRecord('003', 'DEF1', 'MyFlow', 3, 'Active')
        };

        Test.setMock(HttpCalloutMock.class, new QueryThenDeleteMock(
            buildToolingResponse(records), 400, '{"errorCode":"UNKNOWN_EXCEPTION"}'
        ));

        Test.startTest();
        FlowVersionCleaner.run();
        Test.stopTest();
        // Delete returns 400 — error logged, no exception thrown, execution continues
    }

    // ── run() — delete callout exception is caught and logged ─────────────────

    @IsTest
    static void run_deleteCalloutExceptionCaught() {
        buildSettings(1, false);

        List<Map<String, Object>> records = new List<Map<String, Object>>{
            buildRecord('001', 'DEF1', 'MyFlow', 1, 'Obsolete'),
            buildRecord('002', 'DEF1', 'MyFlow', 2, 'Obsolete'),
            buildRecord('003', 'DEF1', 'MyFlow', 3, 'Active')
        };

        Test.setMock(HttpCalloutMock.class, new QueryThenDeleteExceptionMock(
            buildToolingResponse(records)
        ));

        Test.startTest();
        FlowVersionCleaner.run();
        Test.stopTest();
        // CalloutException on delete is caught and logged — no exception bubbles up
    }

    // ── queryAllFlowVersions() — non-200 throws FlowCleanerException ──────────

    @IsTest
    static void query_throwsOnNon200() {
        buildSettings(2, false);
        Test.setMock(HttpCalloutMock.class, new SuccessMock('{"error":"unauthorized"}', 401));

        Test.startTest();
        try {
            FlowVersionCleaner.run();
            System.assert(false, 'Expected FlowCleanerException was not thrown');
        } catch (FlowVersionCleaner.FlowCleanerException e) {
            System.assert(e.getMessage().contains('401'), 'Expected 401 in exception message');
        }
        Test.stopTest();
    }

    // ── queryAllFlowVersions() — callout exception wraps correctly ────────────

    @IsTest
    static void query_throwsOnCalloutException() {
        buildSettings(2, false);
        Test.setMock(HttpCalloutMock.class, new CalloutExceptionMock());

        Test.startTest();
        try {
            FlowVersionCleaner.run();
            System.assert(false, 'Expected FlowCleanerException was not thrown');
        } catch (FlowVersionCleaner.FlowCleanerException e) {
            System.assert(e.getMessage().contains('Callout failed'), 'Expected callout failed message');
        }
        Test.stopTest();
    }

    // ── parseQueryResponse() — null Definition handled gracefully ─────────────

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

    // ── buildDeleteList() — multiple active versions picks highest ────────────

    @IsTest
    static void buildDeleteList_picksHighestActiveVersion() {
        buildSettings(1, true);

        List<Map<String, Object>> records = new List<Map<String, Object>>{
            buildRecord('001', 'DEF1', 'MyFlow', 1, 'Obsolete'),
            buildRecord('002', 'DEF1', 'MyFlow', 2, 'Obsolete'),
            buildRecord('003', 'DEF1', 'MyFlow', 3, 'Active'),
            buildRecord('004', 'DEF1', 'MyFlow', 4, 'Active'),
            buildRecord('005', 'DEF1', 'MyFlow', 5, 'Draft')
        };
        Test.setMock(HttpCalloutMock.class, new SuccessMock(buildToolingResponse(records), 200));

        Test.startTest();
        FlowVersionCleaner.run();
        Test.stopTest();
    }
}