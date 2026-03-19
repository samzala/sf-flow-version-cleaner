public class FlowVersionCleanerQueueable implements Queueable, Database.AllowsCallouts {
    public void execute(QueueableContext ctx) {
        FlowVersionCleaner.run();
    }
}