# Auto Delete Old Salesforce Flow Versions — Free Tool

A free Salesforce unlocked package that automatically deletes obsolete Flow versions, cleans up paused and errored Flow interviews, and fully tears down abandoned Flows on a configurable schedule.

---

## What It Does

**Prunes old inactive Flow versions.** Every time a Flow is modified and activated, the previous version becomes Obsolete. These old versions accumulate silently and block you from deleting fields, classes, and other components that still reference them. Flow Version Cleaner keeps a configurable number of recent inactive versions per Flow and automatically deletes the rest.

**Cleans up paused and errored Flow interviews.** Salesforce will not allow you to delete a Flow version if FlowInterview records are still attached to it — the DELETE will fail. Flow Version Cleaner automatically identifies and deletes all FlowInterview records before removing each version, ensuring deletion always succeeds.

**Tears down abandoned Flows.** Flow Version Cleaner can identify Flow definitions that have been completely inactive for longer than a configurable threshold and delete the entire definition — all versions, all interviews, and the definition itself.

---

## Features

- Automatic version pruning with a configurable keep threshold
- Active and post-active versions are always preserved — never touched
- FlowInterview records deleted before each version — required for deletion to succeed
- Full Flow definition teardown for abandoned Flows past an inactivity threshold
- Dry run mode — logs exactly what would be deleted without removing anything
- Comprehensive audit logging to a custom object with a dedicated tab
- All records from one run share a `Batch_Job_Id__c` for easy querying
- Configurable batch size and cron schedule

---

## Installation

**Install URL (sandbox and production):**
```
https://login.salesforce.com/packaging/installPackage.apexp?p0=04tIj000000LSvoIAG
```

**Or via Salesforce CLI:**
```bash
sf package install --package 04tIj000000LSvoIAG --target-org <your-org-alias> --wait 10
```

---

## Post-Install Setup

> These steps cannot be packaged and must be completed manually after install.

**1. Create a Connected App**
- Setup → External Client App Manager → New. Name: `Flow Version Cleaner`
- Enable OAuth Settings. Callback URL: `https://login.salesforce.com/services/oauth2/success`
- OAuth Scopes: `Manage user data via APIs (api)` only
- Enable Client Credentials Flow
- Policies tab: Permitted Users = `Admin Approved Users are Pre-authorized`
- Select Run As user — must have API access and Manage Flow permission
- Save and note the Consumer Key and Consumer Secret

**2. Create an External Credential**
- Setup → Named Credentials → External Credentials → New
- Label and Name: Label = "Flow Cleaner External Credential", Name = "Flow_Cleaner_External_Credential". Protocol: OAuth 2.0. Flow: Client Credentials with Client Secret
- Identity Provider URL: `https://<yourorg>.my.salesforce.com/services/oauth2/token`
- Check Pass client credentials in request body
- Under Principals, create a Principal named `ClientIDSecret` and enter Consumer Key and Secret

**3. Create a Named Credential**
- Setup → Named Credentials → New
- Label and Name: `FlowCleanerNC`. URL: `https://<yourorg>.my.salesforce.com`
- External Credential: `FlowCleanerEC`. Check Generate Authorization Header

**4. Assign the Permission Set**
- Setup → Permission Sets → `Flow Version Cleaner Admin` → Manage Assignments → assign to running user
- External Credential Principal Access → assign `FlowCleanerEC` principal
- Connected App → Manage → Manage Permission Sets → add `FlowVersionCleanerAdmin`

**5. Configure the Custom Setting**
- Setup → Custom Settings → `Flow Cleanup Settings` → Manage → New (org defaults)
- See Configuration below

---

## Configuration

All behaviour is controlled through the `Flow_Cleanup_Settings__c` Custom Hierarchy Setting.

**`Dry_Run__c` (default: true)**
The safety switch. When true, nothing is deleted — every action is logged so you can see exactly what would happen. Always start here. Only set to false when you are fully satisfied with the dry run results.

**`Inactive_Versions_To_Keep__c` (default: 2)**
How many recent inactive versions to keep per Flow. All older eligible versions are deleted. With a value of 2 and active version v14 — v12 and v13 are kept, v1 through v11 are deleted, v14 and above are always preserved.

**`Batch_Size__c` (default: 100)**
Versions processed per execute() chunk. Reduce to 20–50 for heavily customised orgs with many FlowInterview records per Flow.

**`Delete_Inactive_Flows__c` (default: false)**
Enables full teardown of abandoned Flow definitions. Must be enabled deliberately. Full teardown is irreversible — always run dry run first.

**`Inactive_Flow_Threshold_Months__c` (default: 6)**
Only applies when `Delete_Inactive_Flows__c` is true. A Flow is eligible for teardown when it has no Active version and its most recent LastModifiedDate is older than this value in months.

---

## Usage

**Run manually:**
```apex
Flow_Cleanup_Settings__c s = Flow_Cleanup_Settings__c.getInstance();
Database.executeBatch(new FlowVersionCleaner(), (Integer) s.Batch_Size__c);
```

**Schedule the job:**
```apex
System.schedule('Flow Version Cleaner', '0 0 2 * * ?', new FlowVersionCleanerSchedulable());
```

**Stop the scheduled job:**
```
Setup → Scheduled Jobs → Flow Version Cleaner → Delete
```

> Always stop the scheduled job before uninstalling the package.

---

## Viewing Logs

Open the **Flow Version Cleaner Logs** tab in your org, or query via SOQL:

```sql
SELECT Action__c, COUNT(Id) total
FROM Flow_Version_Cleaner_Log__c
WHERE Batch_Job_Id__c = '7073x000...'
GROUP BY Action__c
```

> `Message__c` is a Long Text Area field — it cannot be used in SOQL WHERE clauses. Query by `Action__c` and check `Message__c` by viewing the record.

---

## Source Code

- **GitHub:** https://github.com/samzala/sf-flow-version-cleaner
- **Install URL:** https://login.salesforce.com/packaging/installPackage.apexp?p0=04tIj000000LSvoIAG
- **Package type:** Unlocked — free, no AppExchange listing required

---

## Author

Samruddhi Zala — [github.com/samzala](https://github.com/samzala)

---

## License

MIT — free to use, modify, and distribute.
