@IsTest
private class FlowVersionCleanerSchedulableTest {

    @IsTest
    static void execute_schedulesAndRuns() {
        Flow_Cleanup_Settings__c settings = new Flow_Cleanup_Settings__c(
            SetupOwnerId                 = UserInfo.getOrganizationId(),
            Inactive_Versions_To_Keep__c = 2,
            Dry_Run__c                   = true
        );
        upsert settings;

        Test.setMock(HttpCalloutMock.class, new EmptyResponseMock());

        Test.startTest();
        System.schedule('Test Flow Cleaner', '0 0 2 * * ?', new FlowVersionCleanerSchedulable());
        Test.stopTest();
    }

    private class EmptyResponseMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('{"done":true,"totalSize":0,"records":[]}');
            return res;
        }
    }
}