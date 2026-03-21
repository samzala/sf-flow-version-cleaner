/**
 * FlowVersionCleaner
 *
 * Batch class that deletes old inactive (Obsolete/Draft) Flow versions while:
 *   - Keeping a configurable number of inactive versions per Flow
 *     (driven by Flow_Cleanup_Settings__c.Inactive_Versions_To_Keep__c)
 *   - ALWAYS preserving any version whose version number is GREATER THAN
 *     the currently active version (e.g. if active = v14, v15+ are never touched)
 *   - If no active version exists, keeps the most recent versionsToKeep versions
 *     and deletes the rest
 *
 * Auth: Uses a Named Credential (FlowCleanerNC) backed by an External Credential
 * with OAuth 2.0 Client Credentials flow. The platform injects the Bearer token
 * automatically — no manual Authorization header required.
 *
 * Prerequisites (one-time org setup):
 *   1. Create a Connected App with Client Credentials flow enabled.
 *   2. Create an External Credential (FlowCleanerEC) with OAuth 2.0 Client
 *      Credentials flow and enter the Consumer Key and Secret.
 *   3. Create a Named Credential (FlowCleanerNC) pointing to the org instance URL
 *      with Generate Authorization Header enabled.
 *   4. Assign the External Credential Principal to the running user's
 *      Permission Set (FlowVersionCleanerAdmin).
 *
 * Design:
 *   - start()   — fetches ALL Flow versions via Tooling API with pagination,
 *                 runs deletion logic, and returns only the IDs to delete.
 *                 All logic is done here — execute() is purely a DELETE executor.
 *   - execute() — receives a chunk of IDs and fires one DELETE callout per ID.
 *                 Each chunk gets its own governor limits so the callout budget
 *                 resets per chunk. Chunk size is driven by Batch_Size__c.
 *   - finish()  — logs the final summary of deleted and failed records.
 *
 * Usage (anonymous Apex):
 *   Flow_Cleanup_Settings__c s = Flow_Cleanup_Settings__c.getInstance();
 *   Database.executeBatch(new FlowVersionCleaner(), (Integer) s.Batch_Size__c);
 *
 * Or schedule it:
 *   System.schedule('Flow Cleaner', '0 0 2 * * ?', new FlowVersionCleanerSchedulable());
 */
global with sharing class FlowVersionCleaner implements Database.Batchable<String>, Database.AllowsCallouts, Database.Stateful {

    // Named Credential label — matches the deployed namedCredential metadata.
    // The platform automatically attaches the Bearer token from the
    // Client Credentials grant — no manual Authorization header required.
    private static final String NC_BASE  = 'callout:FlowCleanerNC';
    private static final String API_PATH = '/services/data/v62.0/tooling/';

    // Stateful — these persist across batch chunks so we can track
    // totals across all execute() calls and report them in finish().
    private Integer totalDeleted = 0;
    private Integer totalFailed  = 0;
    private Boolean dryRun;

    // Stateful map of Flow ID to human-readable label (name + version + status).
    // Built in start() and used in execute() for meaningful debug logging
    // since execute() only receives IDs.
    private Map<String, String> idToLabel = new Map<String, String>();

    // ── Inner wrapper for Tooling API query results ───────────────────────────

    @TestVisible
    global class FlowVersion {
        public String  id;
        public String  definitionId;
        public String  definitionName;
        public Integer versionNumber;
        public String  status;
    }

    // ── Batchable: start ──────────────────────────────────────────────────────
    //
    // Fetches ALL Flow versions from the Tooling API with pagination,
    // groups them by definition, runs the deletion logic to determine
    // which versions to delete, and returns just the IDs as an Iterable<String>.
    // The batch framework then chunks those IDs and passes them to execute().
    //
    // We use Iterable<String> instead of Database.QueryLocator because the
    // data comes from a Tooling API REST callout, not a standard SOQL query.

    global Iterable<String> start(Database.BatchableContext bc) {
        Flow_Cleanup_Settings__c settings = Flow_Cleanup_Settings__c.getInstance();

        if (settings == null || settings.Inactive_Versions_To_Keep__c == null) {
            System.debug('** [FlowVersionCleaner] Flow_Cleanup_Settings__c org defaults not configured. Aborting.');
            return new List<String>();
        }

        Integer versionsToKeep = (Integer) settings.Inactive_Versions_To_Keep__c;
        dryRun                 = (settings.Dry_Run__c == true);

        System.debug('** [FlowVersionCleaner] Starting | versionsToKeep=' + versionsToKeep + ' | dryRun=' + dryRun);

        List<FlowVersion> allVersions = queryAllFlowVersions();

        if (allVersions.isEmpty()) {
            System.debug('** [FlowVersionCleaner] No flow versions found. Nothing to do.');
            return new List<String>();
        }

        Map<String, List<FlowVersion>> byDefinition = groupByDefinition(allVersions);
        List<String> toDelete = buildDeleteList(byDefinition, versionsToKeep, idToLabel);

        System.debug('** [FlowVersionCleaner] Versions identified for deletion: ' + toDelete.size());
        return toDelete;
    }

    // ── Batchable: execute ────────────────────────────────────────────────────
    //
    // Receives a chunk of Flow IDs to delete (chunk size driven by Batch_Size__c).
    // Fires one DELETE callout per ID. Each chunk gets its own governor limits
    // so the callout budget resets per chunk — keeping deletes manageable
    // even on heavily customised orgs with large numbers of versions to delete.
    // In dry run mode, logs the IDs without firing any callouts.

    global void execute(Database.BatchableContext bc, List<String> ids) {
        System.debug('** [FlowVersionCleaner] Deleting chunk of ' + ids.size() + ' versions.');

        if (dryRun) {
            for (String flowId : ids) {
                System.debug('** [FlowVersionCleaner] DRY-RUN — would delete: ' + idToLabel.get(flowId) + ' | Id: ' + flowId);
            }
            return;
        }

        Http http = new Http();
        for (String flowId : ids) {
            HttpRequest req = new HttpRequest();
            req.setEndpoint(NC_BASE + API_PATH + 'sobjects/Flow/' + flowId);
            req.setMethod('DELETE');
            req.setHeader('Accept', 'application/json');
            req.setTimeout(120000);

            try {
                HttpResponse res = http.send(req);
                if (res.getStatusCode() == 204) {
                    System.debug('** [FlowVersionCleaner] Deleted ' + idToLabel.get(flowId) + ' | Id: ' + flowId);
                    totalDeleted++;
                } else {
                    System.debug('** [FlowVersionCleaner] Failed ' + idToLabel.get(flowId) + ' | HTTP ' + res.getStatusCode() + ' | ' + res.getBody());
                    totalFailed++;
                }
            } catch (System.CalloutException e) {
                System.debug('** [FlowVersionCleaner] Callout exception for ' + idToLabel.get(flowId) + ' | ' + e.getMessage());
                totalFailed++;
            }
        }
    }

    // ── Batchable: finish ─────────────────────────────────────────────────────
    // Logs the final summary once all chunks have been processed.

    global void finish(Database.BatchableContext bc) {
        System.debug('** [FlowVersionCleaner] Batch complete | totalDeleted=' + totalDeleted + ' | totalFailed=' + totalFailed);
    }

    // ── Query all Flow versions from Tooling API ──────────────────────────────
    //
    // Uses pagination via nextRecordsUrl to handle orgs with more than 500
    // Flow versions. Each page fetches 500 records at a time.
    // The Named Credential handles Bearer token injection automatically.
    // setTimeout(120000) gives each callout up to 120 seconds to respond —
    // the maximum allowed by the platform.

    @TestVisible
    private static List<FlowVersion> queryAllFlowVersions() {
        List<FlowVersion> allVersions = new List<FlowVersion>();

        String soql = EncodingUtil.urlEncode(
            'SELECT Id, DefinitionId, Definition.DeveloperName, VersionNumber, Status ' +
            'FROM Flow ' +
            'WHERE Status IN (\'Active\', \'Obsolete\', \'Draft\', \'InvalidDraft\') ' +
            'ORDER BY DefinitionId, VersionNumber ASC ' +
            'LIMIT 500',
            'UTF-8'
        );

        String nextPath = API_PATH + 'query/?q=' + soql;

        do {
            if (Limits.getCallouts() >= Limits.getLimitCallouts() - 1) {
                System.debug('** [FlowVersionCleaner] Callout limit reached during pagination. Processing partial results.');
                break;
            }

            HttpRequest req = new HttpRequest();
            req.setEndpoint(NC_BASE + nextPath);
            req.setMethod('GET');
            req.setHeader('Accept', 'application/json');
            req.setTimeout(120000);

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

            Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            allVersions.addAll(parseQueryResponse(res.getBody()));

            Boolean done = (Boolean) body.get('done');
            nextPath = done ? null : (String) body.get('nextRecordsUrl');

            System.debug('** [FlowVersionCleaner] Fetched ' + allVersions.size() + ' versions so far. Done: ' + done);

        } while (nextPath != null);

        System.debug('** [FlowVersionCleaner] Total versions fetched: ' + allVersions.size());
        return allVersions;
    }

    // ── Parse Tooling API JSON response ───────────────────────────────────────
    // Maps raw JSON records from the Tooling API response into FlowVersion
    // wrapper objects. Handles null Definition gracefully — this can occur
    // for Flows whose definition has been deleted from the org.

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
        return versions;
    }

    // ── Group versions by Flow definition ─────────────────────────────────────
    // Groups the flat list of versions into a map keyed by DefinitionId
    // so the deletion logic can evaluate all versions of a Flow together.

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

    // ── Core logic: decide what to delete ─────────────────────────────────────
    //
    // Rules applied per Flow definition:
    //   1. Never delete an Active version.
    //   2. Never delete a version whose versionNumber > activeVersionNumber
    //      (post-active versions may be in flight or under review).
    //   3. From the remaining eligible versions, keep the most recent
    //      versionsToKeep and mark the older ones for deletion.
    //   4. If no active version exists (-1), all versions are eligible and
    //      we simply keep the most recent versionsToKeep of those.
    //
    // Versions are already sorted ASC by VersionNumber from the query,
    // so eligible[0] is always the oldest and eligible[last] is the newest.
    //
    // Also populates idToLabel so execute() can log meaningful messages
    // without needing to re-query the Flow metadata.

    @TestVisible
    private static List<String> buildDeleteList(
        Map<String, List<FlowVersion>> byDefinition,
        Integer versionsToKeep,
        Map<String, String> idToLabel
    ) {
        List<String> toDelete = new List<String>();

        for (String defId : byDefinition.keySet()) {
            List<FlowVersion> versions = byDefinition.get(defId);

            // Find the highest active version number.
            // If no active version exists (-1), all non-active versions are
            // eligible and we simply keep the most recent versionsToKeep.
            Integer activeVersionNumber = -1;
            for (FlowVersion fv : versions) {
                if (fv.status == 'Active' && fv.versionNumber > activeVersionNumber) {
                    activeVersionNumber = fv.versionNumber;
                }
            }

            // Collect versions eligible for deletion:
            // skip Active versions and skip post-active versions.
            List<FlowVersion> eligible = new List<FlowVersion>();
            for (FlowVersion fv : versions) {
                if (fv.status == 'Active') continue;
                if (activeVersionNumber != -1 && fv.versionNumber > activeVersionNumber) {
                    System.debug('** [FlowVersionCleaner] Preserving post-active version ' + fv.definitionName + ' v' + fv.versionNumber + ' (active is v' + activeVersionNumber + ')');
                    continue;
                }
                eligible.add(fv);
            }

            // eligible is sorted ASC — the most recent are at the end.
            // Keep the last versionsToKeep entries and delete the front.
            Integer deleteCount = eligible.size() - versionsToKeep;
            if (deleteCount <= 0) continue;

            for (Integer i = 0; i < deleteCount; i++) {
                FlowVersion fv = eligible[i];
                System.debug('** [FlowVersionCleaner] Queueing ' + fv.definitionName + ' v' + fv.versionNumber + ' (status=' + fv.status + ') for deletion');
                toDelete.add(fv.id);
                idToLabel.put(fv.id, fv.definitionName + ' v' + fv.versionNumber + ' (status=' + fv.status + ')');
            }
        }

        return toDelete;
    }

    // ── Custom exception ──────────────────────────────────────────────────────

    public class FlowCleanerException extends Exception {}
}