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
 *   - Deletes FlowInterview records associated with pruned versions via SOQL + DML
 *   - When Delete_Inactive_Flows__c is enabled, identifies flows that have been
 *     completely inactive for longer than Inactive_Flow_Threshold_Months__c months
 *     and chains InactiveFlowCleaner (Batch 2) to fully tear them down
 *   - Logs every action and informational event to Flow_Version_Cleaner_Log__c
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
 *                 groups by definition, identifies teardown candidates,
 *                 builds the delete list, and returns version IDs as Iterable<String>.
 *                 All business logic lives here — execute() is a pure DELETE executor.
 *   - execute() — deletes FlowInterview records via DML (must happen before callouts),
 *                 then deletes Flow versions via Tooling API callouts.
 *                 Each chunk gets its own governor limits.
 *   - finish()  — logs summary and chains InactiveFlowCleaner if teardown candidates exist.
 *
 * Usage (anonymous Apex):
 *   Flow_Cleanup_Settings__c s = Flow_Cleanup_Settings__c.getInstance();
 *   Database.executeBatch(new FlowVersionCleaner(), (Integer) s.Batch_Size__c);
 *
 * Or schedule it:
 *   System.schedule('Flow Cleaner', '0 0 2 * * ?', new FlowVersionCleanerSchedulable());
 */
public with sharing class FlowVersionCleaner implements Database.Batchable<String>, Database.AllowsCallouts, Database.Stateful {

    private static final String NC_BASE    = 'callout:FlowCleanerNC';
    private static final String API_PATH   = '/services/data/v62.0/tooling/';
    private static final String BATCH_NAME = 'FlowVersionCleaner';

    // ── Stateful fields — persist across batch chunks ─────────────────────────

    private Integer totalDeleted           = 0;
    private Integer totalFailed            = 0;
    private Integer totalPreserved         = 0;
    private Integer totalInterviewsDeleted = 0;
    private Integer totalInterviewsFailed  = 0;
    private Boolean dryRun;
    private Boolean deleteInactiveFlows;
    private Integer inactiveThresholdMonths;
    private Integer batchSize;
    private String  jobId;

    // Maps version ID -> FlowVersion for rich logging in execute().
    // Using Map<String, FlowVersion> instead of Map<String, String> ensures
    // all version fields (name, number, status) are available per chunk.
    private Map<String, FlowVersion> idToVersion = new Map<String, FlowVersion>();

    // Log buffer — bulk inserted at end of each execute() chunk to minimise DML.
    private List<Flow_Version_Cleaner_Log__c> logBuffer = new List<Flow_Version_Cleaner_Log__c>();

    // Teardown candidates passed to InactiveFlowCleaner in finish().
    // @JsonAccess ensures all fields survive serialisation between batch jobs.
    @TestVisible
    private Map<String, List<FlowVersion>> teardownCandidates = new Map<String, List<FlowVersion>>();

    // ── Inner class ───────────────────────────────────────────────────────────
    //
    // @JsonAccess is critical — without it, field values are lost when Salesforce
    // serialises this object to pass between FlowVersionCleaner and InactiveFlowCleaner.

    @TestVisible
    @JsonAccess(serializable='always' deserializable='always')
    public class FlowVersion {
        public String   id;
        public String   definitionId;
        public String   definitionName;
        public Integer  versionNumber;
        public String   status;
        public DateTime versionLastModified;
    }

    // ── start ─────────────────────────────────────────────────────────────────

    public Iterable<String> start(Database.BatchableContext bc) {
        jobId = bc.getJobId();

        Flow_Cleanup_Settings__c settings = Flow_Cleanup_Settings__c.getInstance();

        if (settings == null || settings.Inactive_Versions_To_Keep__c == null) {
            logInfo('Flow_Cleanup_Settings__c org defaults not configured. Aborting.');
            flushLogs();
            return new List<String>();
        }

        Integer versionsToKeep  = (Integer) settings.Inactive_Versions_To_Keep__c;
        dryRun                  = (settings.Dry_Run__c == true);
        deleteInactiveFlows     = (settings.Delete_Inactive_Flows__c == true);
        inactiveThresholdMonths = settings.Inactive_Flow_Threshold_Months__c != null
            ? (Integer) settings.Inactive_Flow_Threshold_Months__c : 0;
        batchSize               = settings.Batch_Size__c != null
            ? (Integer) settings.Batch_Size__c : 100;

        logInfo('Starting | versionsToKeep=' + versionsToKeep
            + ' | dryRun=' + dryRun
            + ' | deleteInactiveFlows=' + deleteInactiveFlows
            + ' | inactiveThresholdMonths=' + inactiveThresholdMonths
            + ' | batchSize=' + batchSize);

        List<FlowVersion> allVersions = queryAllFlowVersions();

        if (allVersions.isEmpty()) {
            logInfo('No flow versions found. Nothing to do.');
            flushLogs();
            return new List<String>();
        }

        logInfo('Total versions fetched: ' + allVersions.size());

        Map<String, List<FlowVersion>> byDefinition = groupByDefinition(allVersions);
        logInfo('Total flow definitions found: ' + byDefinition.size());

        if (deleteInactiveFlows == true && inactiveThresholdMonths > 0) {
            DateTime cutoff = DateTime.now().addMonths(-inactiveThresholdMonths);
            identifyTeardownCandidates(byDefinition, cutoff, teardownCandidates);

            for (String defId : teardownCandidates.keySet()) {
                List<FlowVersion> versions = teardownCandidates.get(defId);
                byDefinition.remove(defId);
                logInfo(versions[0].definitionName
                    + ' marked for full teardown. Versions: ' + versions.size());
            }
            logInfo('Teardown candidates identified: ' + teardownCandidates.size());
        }

        List<String> toDelete = buildDeleteList(byDefinition, versionsToKeep, idToVersion);

        logInfo('Versions identified for deletion: ' + toDelete.size()
            + ' | Definitions for teardown: ' + teardownCandidates.size());

        flushLogs();
        return toDelete;
    }

    // ── execute ───────────────────────────────────────────────────────────────

    public void execute(Database.BatchableContext bc, List<String> ids) {
        logInfo('Processing chunk of ' + ids.size() + ' versions.');

        if (dryRun == true) {
            for (String flowId : ids) {
                FlowVersion fv = idToVersion.get(flowId);
                logEntry(flowId,
                    fv != null ? fv.definitionName : null,
                    fv != null ? fv.versionNumber  : null,
                    fv != null ? fv.status         : null,
                    'Dry Run', 'Would be deleted in live run.');
                totalDeleted++;
            }
            List<String> interviewIds = queryFlowInterviewsByVersionIds(ids);
            if (!interviewIds.isEmpty()) {
                logInfo('DRY-RUN — ' + interviewIds.size() + ' FlowInterview(s) would also be deleted.');
                totalInterviewsDeleted += interviewIds.size();
            } else {
                logInfo('No FlowInterview records found for this chunk.');
            }
            flushLogs();
            return;
        }

        // Step 1: Delete FlowInterview records via DML — MUST happen before callouts.
        List<String> interviewIds = queryFlowInterviewsByVersionIds(ids);
        if (!interviewIds.isEmpty()) {
            logInfo('Deleting ' + interviewIds.size() + ' FlowInterview(s) for this chunk.');
            deleteFlowInterviews(interviewIds);
        } else {
            logInfo('No FlowInterview records found for this chunk.');
        }

        // Step 2: Delete Flow versions via Tooling API callouts.
        Http http = new Http();
        for (String flowId : ids) {
            FlowVersion fv = idToVersion.get(flowId);

            HttpRequest req = new HttpRequest();
            req.setEndpoint(NC_BASE + API_PATH + 'sobjects/Flow/' + flowId);
            req.setMethod('DELETE');
            req.setHeader('Accept', 'application/json');
            req.setTimeout(120000);

            try {
                HttpResponse res = http.send(req);
                if (res.getStatusCode() == 204) {
                    logEntry(flowId,
                        fv != null ? fv.definitionName : null,
                        fv != null ? fv.versionNumber  : null,
                        fv != null ? fv.status         : null,
                        'Deleted', null);
                    totalDeleted++;
                } else {
                    logEntry(flowId,
                        fv != null ? fv.definitionName : null,
                        fv != null ? fv.versionNumber  : null,
                        fv != null ? fv.status         : null,
                        'Failed', 'HTTP ' + res.getStatusCode() + ' | ' + res.getBody());
                    totalFailed++;
                }
            } catch (System.CalloutException e) {
                logEntry(flowId,
                    fv != null ? fv.definitionName : null,
                    fv != null ? fv.versionNumber  : null,
                    fv != null ? fv.status         : null,
                    'Failed', e.getMessage());
                totalFailed++;
            }
        }

        flushLogs();
    }

    // ── finish ────────────────────────────────────────────────────────────────

    public void finish(Database.BatchableContext bc) {
        if (dryRun == true) {
            logInfo('===== DRY-RUN SUMMARY =====');
            logInfo('Versions that would be deleted       : ' + totalDeleted);
            logInfo('Interviews that would be deleted     : ' + totalInterviewsDeleted);
            logInfo('Definitions flagged for teardown     : ' + teardownCandidates.size());
            logInfo('Versions preserved                   : ' + totalPreserved);
            if (!teardownCandidates.isEmpty()) {
                for (String defId : teardownCandidates.keySet()) {
                    List<FlowVersion> versions = teardownCandidates.get(defId);
                    if (versions == null || versions.isEmpty()) continue;
                    DateTime maxLastModified = null;
                    for (FlowVersion fv : versions) {
                        if (fv.versionLastModified != null &&
                            (maxLastModified == null || fv.versionLastModified > maxLastModified)) {
                            maxLastModified = fv.versionLastModified;
                        }
                    }
                    logInfo('TEARDOWN: ' + versions[0].definitionName
                        + ' | versions: ' + versions.size()
                        + ' | last modified: ' + maxLastModified);
                }
            }
            logInfo('===========================');
        } else {
            logInfo('===== BATCH SUMMARY =====');
            logInfo('Versions deleted     : ' + totalDeleted);
            logInfo('Versions failed      : ' + totalFailed);
            logInfo('Versions preserved   : ' + totalPreserved);
            logInfo('Interviews deleted   : ' + totalInterviewsDeleted);
            logInfo('Interviews failed    : ' + totalInterviewsFailed);
            logInfo('Teardown candidates  : ' + teardownCandidates.size());
            logInfo('=========================');
        }

        flushLogs();

        if (!teardownCandidates.isEmpty() && deleteInactiveFlows == true) {
            logInfo('Chaining InactiveFlowCleaner for ' + teardownCandidates.size() + ' definition(s).');
            flushLogs();
            Database.executeBatch(
                new InactiveFlowCleaner(teardownCandidates, dryRun, jobId),
                batchSize != null ? batchSize : 100
            );
        }
    }

    // ── Query all Flow versions with pagination ────────────────────────────────

    @TestVisible
    private static List<FlowVersion> queryAllFlowVersions() {
        List<FlowVersion> allVersions = new List<FlowVersion>();

        String soql = EncodingUtil.urlEncode(
            'SELECT Id, DefinitionId, Definition.DeveloperName, VersionNumber, Status, LastModifiedDate ' +
            'FROM Flow ' +
            'WHERE Status IN (\'Active\', \'Obsolete\', \'Draft\', \'InvalidDraft\') ' +
            'ORDER BY DefinitionId, VersionNumber ASC',
            'UTF-8'
        );

        String nextPath = API_PATH + 'query/?q=' + soql;
        Integer page = 1;

        do {
            Integer remainingCallouts = Limits.getLimitCallouts() - Limits.getCallouts();
            if (remainingCallouts <= 2) {
                System.debug('** [' + BATCH_NAME + '][Warning] Callout limit approaching during pagination. Remaining: '
                    + remainingCallouts + '. Stopping pagination early to avoid runtime failures.');
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
            List<FlowVersion> pageVersions = parseQueryResponse(res.getBody());
            allVersions.addAll(pageVersions);

            Boolean done = (Boolean) body.get('done');
            System.debug('** [' + BATCH_NAME + '][Info] Page ' + page
                + ' fetched ' + pageVersions.size()
                + ' versions. Total: ' + allVersions.size() + '. Done: ' + done);
            page++;
            nextPath = done ? null : (String) body.get('nextRecordsUrl');

        } while (nextPath != null);

        return allVersions;
    }

    // ── Parser ────────────────────────────────────────────────────────────────

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

            String lmd = (String) rec.get('LastModifiedDate');
            fv.versionLastModified = lmd != null
                ? (DateTime) JSON.deserialize('"' + lmd + '"', DateTime.class) : null;

            versions.add(fv);
        }
        return versions;
    }

    // ── Grouping ──────────────────────────────────────────────────────────────

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

    // ── Core logic ────────────────────────────────────────────────────────────
    //
    // Rules:
    //   1. Never delete an Active version.
    //   2. Never delete a version whose versionNumber > activeVersionNumber.
    //   3. Keep the most recent versionsToKeep eligible versions.
    //   4. If no active version exists, keep the most recent versionsToKeep overall.
    //
    // Populates idToVersion (Map<String, FlowVersion>) so execute() has full
    // version details for logging without re-querying.

    @TestVisible
    private static List<String> buildDeleteList(
        Map<String, List<FlowVersion>> byDefinition,
        Integer versionsToKeep,
        Map<String, FlowVersion> idToVersion
    ) {
        List<String> toDelete = new List<String>();

        for (String defId : byDefinition.keySet()) {
            List<FlowVersion> versions = byDefinition.get(defId);

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
                    System.debug('** [' + BATCH_NAME + '][Info] Preserving post-active: '
                        + fv.definitionName + ' v' + fv.versionNumber);
                    continue;
                }
                eligible.add(fv);
            }

            Integer deleteCount = eligible.size() - versionsToKeep;
            if (deleteCount <= 0) continue;

            for (Integer i = 0; i < deleteCount; i++) {
                FlowVersion fv = eligible[i];
                toDelete.add(fv.id);
                idToVersion.put(fv.id, fv);
            }
        }

        return toDelete;
    }

    // ── Identify teardown candidates ──────────────────────────────────────────
    //
    // Two-pass approach to avoid the single-loop bug where maxLastModified
    // is never calculated when Active comes first in the list.
    //
    // Pass 1: check for any Active version — skip the definition if found.
    // Pass 2: find the most recent LastModifiedDate across all versions.

    @TestVisible
    private static void identifyTeardownCandidates(
        Map<String, List<FlowVersion>> byDefinition,
        DateTime cutoff,
        Map<String, List<FlowVersion>> teardownCandidates
    ) {
        for (String defId : byDefinition.keySet()) {
            List<FlowVersion> versions = byDefinition.get(defId);

            // Pass 1 — skip if any Active version exists
            Boolean hasActive = false;
            for (FlowVersion fv : versions) {
                if (fv.status == 'Active') { hasActive = true; break; }
            }
            if (hasActive) continue;

            // Pass 2 — find the most recent LastModifiedDate
            DateTime maxLastModified = null;
            for (FlowVersion fv : versions) {
                if (fv.versionLastModified != null &&
                    (maxLastModified == null || fv.versionLastModified > maxLastModified)) {
                    maxLastModified = fv.versionLastModified;
                }
            }

            if (maxLastModified != null && maxLastModified < cutoff) {
                teardownCandidates.put(defId, versions);
            }
        }
    }

    // ── Query FlowInterview records via SOQL ──────────────────────────────────
    // FlowInterview is a standard sObject — not supported by Tooling API.

    @TestVisible
    private List<String> queryFlowInterviewsByVersionIds(List<String> versionIds) {
        List<String> interviewIds = new List<String>();
        if (versionIds.isEmpty()) return interviewIds;
        for (FlowInterview fi : [
            SELECT Id
            FROM FlowInterview
            WHERE FlowVersionViewId IN :versionIds
        ]) {
            interviewIds.add(fi.Id);
        }
        return interviewIds;
    }

    // ── Delete FlowInterview records via DML ──────────────────────────────────
    // allOrNone=false so one failure does not roll back the rest.

    @TestVisible
    private void deleteFlowInterviews(List<String> interviewIds) {
        List<SObject> toDelete = new List<SObject>();
        for (String intId : interviewIds) {
            toDelete.add(new FlowInterview(Id = intId));
        }
        List<Database.DeleteResult> results = Database.delete(toDelete, false);
        for (Database.DeleteResult dr : results) {
            if (dr.isSuccess()) {
                totalInterviewsDeleted++;
            } else {
                logEntry(dr.getId(), null, null, null, 'Failed',
                    'FlowInterview delete failed: ' + dr.getErrors()[0].getMessage());
                totalInterviewsFailed++;
            }
        }
    }

    // ── Logging ───────────────────────────────────────────────────────────────

    private void logEntry(
        String recordId, String flowName, Integer versionNumber,
        String flowStatus, String action, String message
    ) {
        System.debug('** [' + BATCH_NAME + '][' + action + '] '
            + (flowName      != null ? flowName              : '')
            + (versionNumber != null ? ' v' + versionNumber  : '')
            + (flowStatus    != null ? ' (' + flowStatus + ')': '')
            + (message       != null ? ' | ' + message        : ''));

        logBuffer.add(new Flow_Version_Cleaner_Log__c(
            Batch_Job_Id__c   = jobId,
            Run_Date__c       = System.now(),
            Dry_Run__c        = (dryRun == true),
            Record_Id__c      = recordId,
            Flow_Name__c      = flowName,
            Version_Number__c = versionNumber,
            Flow_Status__c    = flowStatus,
            Action__c         = action,
            Message__c        = message,
            Batch__c          = BATCH_NAME
        ));
    }

    private void logInfo(String message) {
        System.debug('** [' + BATCH_NAME + '][Info] ' + message);
        logBuffer.add(new Flow_Version_Cleaner_Log__c(
            Batch_Job_Id__c = jobId,
            Run_Date__c     = System.now(),
            Dry_Run__c      = (dryRun == true),
            Action__c       = 'Info',
            Message__c      = message,
            Batch__c        = BATCH_NAME
        ));
    }

    private void logWarning(String message) {
        System.debug('** [' + BATCH_NAME + '][Warning] ' + message);
        logBuffer.add(new Flow_Version_Cleaner_Log__c(
            Batch_Job_Id__c = jobId,
            Run_Date__c     = System.now(),
            Dry_Run__c      = (dryRun == true),
            Action__c       = 'Warning',
            Message__c      = message,
            Batch__c        = BATCH_NAME
        ));
    }

    private void flushLogs() {
        if (!logBuffer.isEmpty()) {
            insert logBuffer;
            logBuffer.clear();
        }
    }

    // ── Custom exception ──────────────────────────────────────────────────────

    public class FlowCleanerException extends Exception {}
}