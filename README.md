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
- Setup → Named Credentials → External Credentials → New
- Label: `FlowCleanerEC`
- Name: `FlowCleanerEC`
- Authentication Protocol: `OAuth 2.0`
- Authentication Flow: `Client Credentials`
- Identity Provider URL: `https://<your-instance>.my.salesforce.com/services/oauth2/token`
- Under Principals → New Principal:
  - Name: `FlowCleanerPrincipal`
  - Enter the **Consumer Key** and **Consumer Secret** from step 1

### 3. Create a Named Credential
- Setup → Named Credentials → New
- Label: `FlowCleanerNC`
- Name: `FlowCleanerNC`
- URL: `https://<your-instance>.my.salesforce.com`
- External Credential: `FlowCleanerEC`
- Check **Generate Authorization Header**

### 4. Assign the Permission Set
- Setup → Permission Sets → Flow Version Cleaner Admin
- Click **Manage Assignments** → Add the user who will run the job
- Go back to External Credentials → FlowCleanerEC → Principals → FlowCleanerPrincipal
- Assign the principal to the **Flow Version Cleaner Admin** permission set
- Add the permission set to the connected app that got created.

### 5. Configure the Custom Setting
- Setup → Custom Settings → Flow Cleanup Settings → Manage → New
- **Inactive Versions To Keep** — number of inactive versions to keep per flow (e.g. `2`)
- **Dry Run** — set to `true` initially to verify before enabling live deletion

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