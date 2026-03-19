/**
 * FlowVersionCleaner
 *
 * Deletes old inactive (Obsolete/Draft) flow versions while:
 *   - Keeping a configurable number of inactive versions per flow
 *     (driven by Flow_Cleanup_Settings__c.Inactive_Versions_To_Keep__c)
 *   - ALWAYS preserving any version whose version number is GREATER THAN
 *     the currently active version (e.g. if active = v14, v15+ are never touched)
 *   - If no active version exists, keeps the most recent versionsToKeep versions
 *     and deletes the rest
 *
 * Auth: Uses a Named Credential (FlowCleanerNC) backed by an External Credential
 * with OAuth 2.0 Client Credentials flow.
 *
 * Usage (anonymous Apex):
 *   FlowVersionCleaner.run();
 *
 * Or schedule it:
 *   System.schedule('Flow Cleaner', '0 0 2 * * ?', new FlowVersionCleanerSchedulable());
 */
public with sharing class FlowVersionCleaner {

    private static final String NC_BASE  = 'callout:FlowCleanerNC';
    private static final String API_PATH = '/services/data/v62.0/tooling/';

    @TestVisible
    private class FlowVersion {
        public String  id;
        public String  definitionId;
        public String  definitionName;
        public Integer versionNumber;
        public String  status;
    }

    public static void run() {
        Flow_Cleanup_Settings__c settings = Flow_Cleanup_Settings__c.getInstance();

        if (settings == null || settings.Inactive_Versions_To_Keep__c == null) {
            System.debug(LoggingLevel.ERROR, '[FlowVersionCleaner] Flow_Cleanup_Settings__c org defaults not configured. Aborting.');
            return;
        }

        Integer versionsToKeep = (Integer) settings.Inactive_Versions_To_Keep__c;
        Boolean dryRun         = (settings.Dry_Run__c == true);

        System.debug(LoggingLevel.INFO, '[FlowVersionCleaner] Starting | versionsToKeep=' + versionsToKeep + ' | dryRun=' + dryRun);

        List<FlowVersion> allVersions = queryAllFlowVersions();
        if (allVersions.isEmpty()) {
            System.debug(LoggingLevel.INFO, '[FlowVersionCleaner] No flow versions found. Nothing to do.');
            return;
        }

        Map<String, List<FlowVersion>> byDefinition = groupByDefinition(allVersions);
        List<String> toDelete = buildDeleteList(byDefinition, versionsToKeep);

        System.debug(LoggingLevel.INFO, '[FlowVersionCleaner] Versions identified for deletion: ' + toDelete.size());

        if (toDelete.isEmpty()) {
            System.debug(LoggingLevel.INFO, '[FlowVersionCleaner] Nothing to delete.');
            return;
        }

        if (dryRun) {
            System.debug(LoggingLevel.INFO, '[FlowVersionCleaner] DRY-RUN — would delete flow version IDs: ' + JSON.serialize(toDelete));
        } else {
            deleteFlowVersions(toDelete);
        }

        System.debug(LoggingLevel.INFO, '[FlowVersionCleaner] Complete.');
    }

    @TestVisible
    private static List<FlowVersion> queryAllFlowVersions() {
        String soql = EncodingUtil.urlEncode(
            'SELECT Id, DefinitionId, Definition.DeveloperName, VersionNumber, Status ' +
            'FROM Flow ' +
            'WHERE Status IN (\'Active\', \'Obsolete\', \'Draft\', \'InvalidDraft\') ' +
            'ORDER BY DefinitionId, VersionNumber ASC',
            'UTF-8'
        );

        HttpRequest req = new HttpRequest();
        req.setEndpoint(NC_BASE + API_PATH + 'query/?q=' + soql);
        req.setMethod('GET');
        req.setHeader('Accept', 'application/json');

        HttpResponse res;
        try {
            res = new Http().send(req);
        } catch (System.CalloutException e) {
            throw new FlowCleanerException(
                'Callout failed. Verify Named Credential, External Credential principal, ' +
                'and Connected App permissions. Error: ' + e.getMessage()
            );
        }

        if (res.getStatusCode() != 200) {
            throw new FlowCleanerException(
                'Tooling API query failed (' + res.getStatusCode() + '): ' + res.getBody()
            );
        }

        System.debug(LoggingLevel.INFO, '[FlowVersionCleaner] Tooling API query succeeded. HTTP 200.');
        return parseQueryResponse(res.getBody());
    }

    @TestVisible
    private static List<FlowVersion> parseQueryResponse(String jsonBody) {
        Map<String, Object> response = (Map<String, Object>) JSON.deserializeUntyped(jsonBody);
        List<Object> records = (List<Object>) response.get('records');

        List<FlowVersion> versions = new List<FlowVersion>();
        for (Object r : records) {
            Map<String, Object> rec = (Map<String, Object>) r;
            Map<String, Object> def = (Map<String, Object>) rec.get('Definition');

            FlowVersion fv    = new FlowVersion();
            fv.id             = (String)  rec.get('Id');
            fv.definitionId   = (String)  rec.get('DefinitionId');
            fv.definitionName = def != null ? (String) def.get('DeveloperName') : 'Unknown';
            fv.versionNumber  = (Integer) rec.get('VersionNumber');
            fv.status         = (String)  rec.get('Status');
            versions.add(fv);
        }

        System.debug(LoggingLevel.INFO, '[FlowVersionCleaner] Parsed ' + versions.size() + ' flow versions.');
        return versions;
    }

    @TestVisible
    private static Map<String, List<FlowVersion>> groupByDefinition(List<FlowVersion> versions) {
        Map<String, List<FlowVersion>> grouped = new Map<String, List<FlowVersion>>();
        for (FlowVersion fv : versions) {
            if (!grouped.containsKey(fv.definitionId)) {
                grouped.put(fv.definitionId, new List<FlowVersion>());
            }
            grouped.get(fv.definitionId).add(fv);
        }
        return grouped;
    }

    @TestVisible
    private static List<String> buildDeleteList(
        Map<String, List<FlowVersion>> byDefinition,
        Integer versionsToKeep
    ) {
        List<String> toDelete = new List<String>();

        for (String defId : byDefinition.keySet()) {
            List<FlowVersion> versions = byDefinition.get(defId);

            // Find the highest active version number.
            // If no active version exists (-1), all non-active versions are eligible
            // and we simply keep the most recent versionsToKeep of those.
            Integer activeVersionNumber = -1;
            for (FlowVersion fv : versions) {
                if (fv.status == 'Active' && fv.versionNumber > activeVersionNumber) {
                    activeVersionNumber = fv.versionNumber;
                }
            }

            List<FlowVersion> eligible = new List<FlowVersion>();
            for (FlowVersion fv : versions) {
                if (fv.status == 'Active') continue;
                if (activeVersionNumber != -1 && fv.versionNumber > activeVersionNumber) {
                    System.debug(LoggingLevel.INFO, '[FlowVersionCleaner] Preserving post-active version ' + fv.definitionName + ' v' + fv.versionNumber + ' (active is v' + activeVersionNumber + ')');
                    continue;
                }
                eligible.add(fv);
            }

            Integer deleteCount = eligible.size() - versionsToKeep;
            if (deleteCount <= 0) continue;

            for (Integer i = 0; i < deleteCount; i++) {
                FlowVersion fv = eligible[i];
                System.debug(LoggingLevel.INFO, '[FlowVersionCleaner] Queueing ' + fv.definitionName + ' v' + fv.versionNumber + ' (Id=' + fv.id + ', status=' + fv.status + ') for deletion');
                toDelete.add(fv.id);
            }
        }

        return toDelete;
    }

    @TestVisible
    private static void deleteFlowVersions(List<String> ids) {
        Http http = new Http();
        for (String flowId : ids) {
            if (Limits.getCallouts() >= Limits.getLimitCallouts() - 1) {
                System.debug(LoggingLevel.WARN, '[FlowVersionCleaner] Callout limit reached. Skipping remaining IDs.');
                break;
            }
            HttpRequest req = new HttpRequest();
            req.setEndpoint(NC_BASE + API_PATH + 'sobjects/Flow/' + flowId);
            req.setMethod('DELETE');
            req.setHeader('Accept', 'application/json');
            try {
                HttpResponse res = http.send(req);
                if (res.getStatusCode() == 204) {
                    System.debug(LoggingLevel.INFO, '[FlowVersionCleaner] Successfully deleted Flow Id: ' + flowId);
                } else {
                    System.debug(LoggingLevel.ERROR, '[FlowVersionCleaner] Failed Id ' + flowId + ' | HTTP ' + res.getStatusCode() + ' | ' + res.getBody());
                }
            } catch (System.CalloutException e) {
                System.debug(LoggingLevel.ERROR, '[FlowVersionCleaner] Callout exception for Id ' + flowId + ': ' + e.getMessage());
            }
        }
    }

    public class FlowCleanerException extends Exception {}
}