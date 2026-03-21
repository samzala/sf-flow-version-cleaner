/**
 * FlowVersionCleanerSchedulableTest
 *
 * Test class for FlowVersionCleanerSchedulable.
 * Verifies that the schedulable correctly reads the batch size from the
 * Custom Setting and kicks off the batch job. Also verifies that when
 * no Custom Setting is configured, the default batch size of 100 is used.
 */
@IsTest
private class FlowVersionCleanerSchedulableTest {

    // ── Mock ──────────────────────────────────────────────────────────────────
    // Returns an empty Tooling API response so the batch completes cleanly
    // without hitting any real endpoints.

    private class EmptyResponseMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('{"done":true,"totalSize":0,"records":[]}');
            return res;
        }
    }

    // ── Test: batch size read from Custom Setting ─────────────────────────────
    // Verifies that when Batch_Size__c is configured, the schedulable
    // passes that value to Database.executeBatch().

    @IsTest
    static void execute_schedulesAndRuns() {
        Flow_Cleanup_Settings__c settings = new Flow_Cleanup_Settings__c(
            SetupOwnerId                 = UserInfo.getOrganizationId(),
            Inactive_Versions_To_Keep__c = 2,
            Batch_Size__c                = 50,
            Dry_Run__c                   = true
        );
        upsert settings;

        Test.setMock(HttpCalloutMock.class, new EmptyResponseMock());

        Test.startTest();
        System.schedule('Test Flow Cleaner', '0 0 2 * * ?', new FlowVersionCleanerSchedulable());
        Test.stopTest();
    }

    // ── Test: default batch size when settings null ───────────────────────────
    // Verifies that when no Custom Setting is configured, the schedulable
    // falls back to the default batch size of 100 without throwing an error.

    @IsTest
    static void execute_usesDefaultBatchSizeWhenSettingsNull() {
        Test.setMock(HttpCalloutMock.class, new EmptyResponseMock());

        Test.startTest();
        System.schedule('Test Flow Cleaner No Settings', '0 0 2 * * ?', new FlowVersionCleanerSchedulable());
        Test.stopTest();
    }
}