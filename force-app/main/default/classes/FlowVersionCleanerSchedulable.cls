/**
 * FlowVersionCleanerSchedulable
 *
 * Schedulable entry point for the Flow Version Cleaner batch job.
 * Reads the batch size from the Custom Hierarchy Setting and kicks off
 * the batch. If no setting is configured, defaults to a batch size of 100.
 *
 * Usage (anonymous Apex):
 *   System.schedule('Flow Cleaner', '0 0 2 * * ?', new FlowVersionCleanerSchedulable());
 *
 * Cron expression breakdown:
 *   0 0 2 * * ? = every day at 2:00 AM
 */
public class FlowVersionCleanerSchedulable implements Schedulable {

    public void execute(SchedulableContext sc) {
        Flow_Cleanup_Settings__c settings = Flow_Cleanup_Settings__c.getInstance();

        // Read batch size from Custom Setting.
        // If not configured, default to 100 — a safe value for most orgs.
        // For heavily customised orgs with slow Tooling API responses,
        // reduce this value to avoid callout timeouts per chunk.
        Integer batchSize = settings != null && settings.Batch_Size__c != null
            ? (Integer) settings.Batch_Size__c
            : 100;

        System.debug('** [FlowVersionCleanerSchedulable] Kicking off batch with size: ' + batchSize);

        Database.executeBatch(new FlowVersionCleaner(), batchSize);
    }
}