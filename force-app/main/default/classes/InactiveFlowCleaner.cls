/**
 * InactiveFlowCleaner
 *
 * Batch 2 — performs full teardown of Flow definitions that have been completely
 * inactive for longer than the configured threshold.
 *
 * Chained from FlowVersionCleaner.finish() when teardown candidates are found.
 *
 * Teardown sequence per definition:
 *   1. Query and delete FlowInterview records via SOQL + DML (before any callouts).
 *   2. Delete all Flow versions via Tooling API callouts.
 *      Salesforce auto-removes the FlowDefinition when the last version is deleted.
 *
 * Logs every action to Flow_Version_Cleaner_Log__c using the same Batch_Job_Id__c
 * as FlowVersionCleaner so all records from one run are queryable together.
 *
 * Uses the same Named Credential (FlowCleanerNC) as FlowVersionCleaner.
 */
public without sharing class InactiveFlowCleaner implements Database.Batchable<String>, Database.AllowsCallouts, Database.Stateful {

    private static final String NC_BASE    = 'callout:FlowCleanerNC';
    private static final String API_PATH   = '/services/data/v62.0/tooling/';
    private static final String BATCH_NAME = 'InactiveFlowCleaner';

    // teardownPlans uses FlowVersionCleaner.FlowVersion which is annotated
    // @JsonAccess — fields survive serialisation between batch jobs.
    private Map<String, List<FlowVersionCleaner.FlowVersion>> teardownPlans;
    private Boolean dryRun;
    private String  jobId;

    // Stateful counters
    private Integer totalVersionsDeleted     = 0;
    private Integer totalVersionsFailed      = 0;
    private Integer totalInterviewsDeleted   = 0;
    private Integer totalInterviewsFailed    = 0;
    private Integer totalDefinitionsTornDown = 0;
    private Integer totalDefinitionsFailed   = 0;

    // Dry run counters
    private Integer dryRunVersionCount    = 0;
    private Integer dryRunInterviewCount  = 0;
    private Integer dryRunDefinitionCount = 0;

    // Log buffer — bulk inserted at end of each execute() chunk.
    private List<Flow_Version_Cleaner_Log__c> logBuffer = new List<Flow_Version_Cleaner_Log__c>();

    // ── Constructor ───────────────────────────────────────────────────────────

    public InactiveFlowCleaner(
        Map<String, List<FlowVersionCleaner.FlowVersion>> teardownPlans,
        Boolean dryRun,
        String jobId
    ) {
        this.teardownPlans = teardownPlans;
        this.dryRun        = dryRun;
        this.jobId         = jobId;
    }

    // ── start ─────────────────────────────────────────────────────────────────

    public Iterable<String> start(Database.BatchableContext bc) {
        logInfo('Starting teardown for ' + teardownPlans.size()
            + ' definition(s) | dryRun=' + dryRun);
        flushLogs();
        return new List<String>(teardownPlans.keySet());
    }

    // ── execute ───────────────────────────────────────────────────────────────

    public void execute(Database.BatchableContext bc, List<String> definitionIds) {
        for (String defId : definitionIds) {
            List<FlowVersionCleaner.FlowVersion> versions = teardownPlans.get(defId);

            if (versions == null || versions.isEmpty()) {
                logWarning('No versions found for definition ' + defId + '. Skipping.');
                continue;
            }

            String defName = versions[0].definitionName;
            logInfo('Processing: ' + defName + ' (' + defId + ') | versions: ' + versions.size());

            if (dryRun == true) {
                logDryRun(defId, defName, versions);
                continue;
            }

            // Step 1: Delete FlowInterview records via DML — MUST be before callouts.
            Boolean interviewsOk = deleteInterviewsForDefinition(defId, defName, versions);
            if (!interviewsOk) {
                logEntry(null, defName, null, null, 'Failed',
                    'Interview deletion failed — version deletion skipped.');
                totalDefinitionsFailed++;
                continue;
            }

            // Step 2: Delete Flow versions via Tooling API callouts.
            Boolean versionsOk = deleteVersionsForDefinition(versions);
            if (!versionsOk) {
                logEntry(null, defName, null, null, 'Failed',
                    'Version deletion partially failed.');
                totalDefinitionsFailed++;
                continue;
            }

            totalDefinitionsTornDown++;
            logInfo('Successfully torn down ' + defName + ' (' + defId + ')');
        }

        flushLogs();
    }

    // ── finish ────────────────────────────────────────────────────────────────

    public void finish(Database.BatchableContext bc) {
        if (dryRun == true) {
            logInfo('===== DRY-RUN SUMMARY =====');
            logInfo('Definitions that would be torn down : ' + dryRunDefinitionCount);
            logInfo('Versions that would be deleted      : ' + dryRunVersionCount);
            logInfo('Interviews that would be deleted    : ' + dryRunInterviewCount);
            logInfo('===========================');
        } else {
            logInfo('===== BATCH SUMMARY =====');
            logInfo('Definitions torn down : ' + totalDefinitionsTornDown);
            logInfo('Definitions failed    : ' + totalDefinitionsFailed);
            logInfo('Versions deleted      : ' + totalVersionsDeleted);
            logInfo('Versions failed       : ' + totalVersionsFailed);
            logInfo('Interviews deleted    : ' + totalInterviewsDeleted);
            logInfo('Interviews failed     : ' + totalInterviewsFailed);
            logInfo('=========================');
        }
        flushLogs();
    }

    // ── Dry-run logging ───────────────────────────────────────────────────────

    private void logDryRun(
        String defId,
        String defName,
        List<FlowVersionCleaner.FlowVersion> versions
    ) {
        logInfo('DRY-RUN — would fully teardown: ' + defName
            + ' (' + defId + ') | versions: ' + versions.size());

        List<String> versionIds = new List<String>();
        for (FlowVersionCleaner.FlowVersion fv : versions) {
            versionIds.add(fv.id);
            logEntry(fv.id, fv.definitionName, fv.versionNumber, fv.status,
                'Dry Run', 'Would be torn down in live run.');
        }

        List<String> interviewIds = queryFlowInterviews(versionIds);
        if (!interviewIds.isEmpty()) {
            logInfo('DRY-RUN — ' + interviewIds.size()
                + ' FlowInterview(s) would also be deleted for ' + defName);
        }

        dryRunDefinitionCount++;
        dryRunVersionCount   += versions.size();
        dryRunInterviewCount += interviewIds.size();
    }

    // ── Query FlowInterview records via SOQL ──────────────────────────────────
    // FlowInterview is a standard sObject — not supported by Tooling API.

    @TestVisible
    private List<String> queryFlowInterviews(List<String> versionIds) {
        List<String> interviewIds = new List<String>();
        if (versionIds.isEmpty()) return interviewIds;
        // FlowVersionViewId is a plain String field — no Id normalization occurs in SOQL.
        // Tooling API returns 18-char Ids; the field may store 15-char. Include both forms.
        Set<String> idSet = new Set<String>();
        for (String s : versionIds) {
            if (String.isBlank(s)) continue;
            idSet.add(s);
            if (s.length() == 18) {
                idSet.add(s.substring(0, 15));
            } else if (s.length() == 15) {
                try { idSet.add(String.valueOf((Id) s)); } catch (Exception e) {}
            }
        }
        for (FlowInterview fi : [
            SELECT Id
            FROM FlowInterview
            WHERE FlowVersionViewId IN :idSet
        ]) {
            interviewIds.add(fi.Id);
        }
        return interviewIds;
    }

    // ── Delete FlowInterview records via DML ──────────────────────────────────
    // Must run BEFORE any Tooling API callouts in execute().

    private Boolean deleteInterviewsForDefinition(
        String defId,
        String defName,
        List<FlowVersionCleaner.FlowVersion> versions
    ) {
        List<String> versionIds = new List<String>();
        for (FlowVersionCleaner.FlowVersion fv : versions) {
            versionIds.add(fv.id);
        }

        List<String> interviewIds = queryFlowInterviews(versionIds);
        if (interviewIds.isEmpty()) {
            logInfo('No interviews found for ' + defName);
            return true;
        }

        logInfo('Deleting ' + interviewIds.size() + ' interview(s) for ' + defName);

        List<SObject> toDelete = new List<SObject>();
        for (String intId : interviewIds) {
            toDelete.add(new FlowInterview(Id = intId));
        }

        List<Database.DeleteResult> results = Database.delete(toDelete, false);
        Boolean allOk = true;
        for (Database.DeleteResult dr : results) {
            if (dr.isSuccess()) {
                totalInterviewsDeleted++;
            } else {
                logEntry(dr.getId(), defName, null, null, 'Failed',
                    'FlowInterview delete failed: ' + dr.getErrors()[0].getMessage());
                totalInterviewsFailed++;
                allOk = false;
            }
        }
        return allOk;
    }

    // ── Delete Flow versions via Tooling API ──────────────────────────────────
    // Runs AFTER all DML — no DML calls after this point.

    private Boolean deleteVersionsForDefinition(
        List<FlowVersionCleaner.FlowVersion> versions
    ) {
        Http http = new Http();
        Boolean allOk = true;

        for (FlowVersionCleaner.FlowVersion fv : versions) {
            if (Limits.getCallouts() >= Limits.getLimitCallouts() - 1) {
                logWarning('Callout limit reached during version deletion.');
                allOk = false;
                break;
            }

            HttpRequest req = new HttpRequest();
            req.setEndpoint(NC_BASE + API_PATH + 'sobjects/Flow/' + fv.id);
            req.setMethod('DELETE');
            req.setHeader('Accept', 'application/json');
            req.setTimeout(120000);

            try {
                HttpResponse res = http.send(req);
                if (res.getStatusCode() == 204) {
                    logEntry(fv.id, fv.definitionName, fv.versionNumber, fv.status,
                        'Teardown', null);
                    totalVersionsDeleted++;
                } else if (res.getStatusCode() == 400
                        && res.getBody().contains('DEPENDENCY_EXISTS')) {
                    // A FlowInterview still references this version — missed by bulk query.
                    // Delete it now and retry once.
                    logEntry(fv.id, fv.definitionName, fv.versionNumber, fv.status,
                        'Warning', 'DEPENDENCY_EXISTS — retrying after late interview cleanup.');
                    List<String> lateInterviewIds = queryFlowInterviews(
                        new List<String>{ fv.id });
                    if (!lateInterviewIds.isEmpty()) {
                        List<SObject> toDelete = new List<SObject>();
                        for (String intId : lateInterviewIds) {
                            toDelete.add(new FlowInterview(Id = intId));
                        }
                        List<Database.DeleteResult> drs = Database.delete(toDelete, false);
                        for (Database.DeleteResult dr : drs) {
                            if (dr.isSuccess()) {
                                totalInterviewsDeleted++;
                            } else {
                                logEntry(dr.getId(), fv.definitionName, null, null, 'Failed',
                                    'Late FlowInterview delete failed: ' + dr.getErrors()[0].getMessage());
                                totalInterviewsFailed++;
                            }
                        }
                    }
                    HttpResponse retry = http.send(req);
                    if (retry.getStatusCode() == 204) {
                        logEntry(fv.id, fv.definitionName, fv.versionNumber, fv.status,
                            'Teardown', 'Succeeded after late interview cleanup.');
                        totalVersionsDeleted++;
                    } else {
                        logEntry(fv.id, fv.definitionName, fv.versionNumber, fv.status,
                            'Teardown Failed',
                            'HTTP ' + retry.getStatusCode() + ' | ' + retry.getBody());
                        totalVersionsFailed++;
                        allOk = false;
                    }
                } else {
                    logEntry(fv.id, fv.definitionName, fv.versionNumber, fv.status,
                        'Teardown Failed',
                        'HTTP ' + res.getStatusCode() + ' | ' + res.getBody());
                    totalVersionsFailed++;
                    allOk = false;
                }
            } catch (System.CalloutException e) {
                logEntry(fv.id, fv.definitionName, fv.versionNumber, fv.status,
                    'Teardown Failed', e.getMessage());
                totalVersionsFailed++;
                allOk = false;
            }
        }
        return allOk;
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
}