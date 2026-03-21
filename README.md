# Flow Version Cleaner

A Salesforce unlocked package that automatically cleans up obsolete and draft 
Flow versions in your org, keeping it tidy and within platform limits.

## What it does

- Queries all Flow versions via the Tooling API
- For each Flow, keeps a configurable number of the most recent inactive versions
- Always preserves the active version
- Always preserves any version newer than the active version
- If no active version exists, keeps the most recent inactive versions
- Deletes the rest
- Supports dry run mode so you can verify before deleting anything

## Install

[Click here to install](https://login.salesforce.com/packaging/installPackage.apexp?p0=04tIS000000U2bxYAC)

Or via Salesforce CLI:
```powershell
sf package install --package 04tIS000000U2bxYAC --target-org <your-org-alias> --wait 10
```

## Post-Install Setup

### 1. Create a Connected App
1. Go to Setup → External Client App Manager→ New Connected App.
2. Enable OAuth Settings.
3. Callback URL: https://login.salesforce.com/services/oauth2/success
4. Add scopes: Full access (full) and Perform requests at any time (refresh_token).
5. Enable Client Credentials Flow.
6. Set Run As to a user with API access and Manage Flow permission.
7. Save
8. Edit the Policies tab under App Policies, select the “Manage user data via APIs (api)”
9. Under Plugin Policies>> Permitted User set “Admin Approved users are pre-authorized”
10. On the same tab, Enable the Client Credentials Flow and select the run as user and save.
11. Edit settings tab and under OAuth Scopes, select “Manage user data via APIs (api)” and remove other scopes. Save
12. Save and note the Consumer Key and Consumer Secret.

### 2. Create an External Credential
1.	Go to Setup → Named Credentials → External Credentials → New.
2.	Set Label and Name to Flow Cleaner External Credential.
3.	Set Authentication Protocol to OAuth 2.0 and Authentication Flow to Client Credentials with Client Secret Flow.
4.	Set Identity Provider URL to https://<yourorg>.my.salesforce.com/services/oauth2/token.
5.	Check the Pass client credentials in request body checkbox and save.
6.	Under Principals on the same page, create a new Principal named “ClientIDSecret” and enter the Consumer Key and Consumer Secret from Step 2.

### 3. Create a Named Credential
1.	Go to Setup → Named Credentials → New.
2.	Set Label and Name to FlowCleanerNC.
3.	Set URL to https://<yourorg>.my.salesforce.com.
4.	Set External Credential to FlowCleanerEC.
5.	Check Generate Authorization Header.

### 4. Assign the Permission Set
1.	Go to Setup → Permission Sets → Flow Version Cleaner Admin.
2.	Click Manage Assignments and assign it to the user who will run the job.
3.	On the FlowVersionCleanerAdmin Permissionset, assign the External Credential just created to External Credential Principle Access.

### 5. Configure the Custom Setting
1.	Go to Setup → Custom Settings → Flow Cleanup Settings → Manage → New.
2.	Set Inactive Versions To Keep — number of inactive versions to retain per Flow (e.g. 2).
3.	Set Batch Size — number of DELETE callouts per batch chunk (e.g. 10 for heavily customised orgs, up to 100 for smaller orgs). Recommended: 20
4.	Set Dry Run to true for the first run.


### 6. Schedule the Job
Run this in Anonymous Apex:
```apex
System.schedule('Flow Version Cleaner', '0 0 2 * * ?', new FlowVersionCleanerSchedulable());
```
This schedules the job to run daily at 2am. Adjust the cron expression as needed.

## First Run

Keep **Dry Run** enabled on the first run and check the debug logs to verify 
the correct versions are being identified before enabling live deletion.

Once happy, go back to the Custom Setting and set **Dry Run** to `false`.

## Uninstalling

Before uninstalling the package:
1. Stop the scheduled job via Setup → Scheduled Jobs
2. Then uninstall the package via Setup → Installed Packages

## License

MIT