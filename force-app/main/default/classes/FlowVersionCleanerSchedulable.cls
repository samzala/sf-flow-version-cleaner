/**
 * FlowVersionCleanerSchedulable
 *
 * Makes FlowVersionCleaner schedulable via the standard Salesforce scheduler.
 *
 * Schedule via Anonymous Apex:
 *   // Run daily at 2 AM
 *   System.schedule('Flow Version Cleaner', '0 0 2 * * ?', new FlowVersionCleanerSchedulable());
 */
public class FlowVersionCleanerSchedulable implements Schedulable {
    public void execute(SchedulableContext sc) {
        System.enqueueJob(new FlowVersionCleanerQueueable());
    }
}