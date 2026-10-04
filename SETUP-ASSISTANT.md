# First-time setup assistant (Windows)

This assistant configures Supabase connection variables on one Netlify site and GitHub Actions secrets without editing either provider's Environment Variables page. It also offers to start database migrations for a new, blank Supabase project.

## Before starting

Create the Supabase project, GitHub repository, and Netlify site first. Connect the GitHub repository to Netlify and deploy the repository once so the site exists. Upload or push this project, including `setup-assistant.bat`, `scripts/setup-assistant.ps1`, and the workflow files, to the repository's `main` branch.

Have these details ready:

- Supabase project URL, publishable key, project ID, service-role key, database password, and a Supabase personal access token with permissions to deploy functions and migrations.
- Netlify site ID and a Netlify personal access token that can manage site environment variables and deploys.
- GitHub repository name in `owner/repository` format. The GitHub account used in the browser sign-in must administer this repository.

## Run it

Download or clone the project to the Windows computer, then double-click `setup-assistant.bat`. If Windows asks, approve running the local setup script. The assistant will:

1. Prompt for Supabase values and secrets.
2. Write the Supabase and Netlify deployment variables to the selected Netlify site, mark server credentials as secret, and queue a new deploy.
3. Sign in to GitHub in a browser and set `SUPABASE_ACCESS_TOKEN`, `SUPABASE_PROJECT_ID`, and `SUPABASE_DB_PASSWORD` as repository Actions secrets.
4. Offer to run `deploy-supabase-migrations.yml` through GitHub Actions.

The migration option is for a **new, blank Supabase project only**. If SQL migrations were already applied manually, answer `N`; applying them again can fail because the database migration history may not match.

## After it finishes

Wait for the Netlify deploy to complete, then open the site and register the first admin. The migration workflow can also be run later from GitHub **Actions → Apply Supabase database migrations → Run workflow**. The existing Send Email Auth Hook deployment workflow uses the GitHub secrets created by the assistant.

The assistant does not save submitted credentials into project files or print them. The Netlify token remains in Netlify because the app's database setup function uses it to update site configuration. Revoke that token in Netlify if you no longer want the app's setup function to manage environment variables.

## Troubleshooting

- **GitHub CLI cannot be found:** install it from [cli.github.com](https://cli.github.com/) and run the assistant again.
- **Netlify returned 401/403:** check the access token and that it can manage the selected site and environment variables.
- **Migration workflow not found:** confirm the workflow file is on `main` and GitHub Actions are enabled for the repository.
- **Migration failed because objects already exist:** do not repeatedly rerun it. The project likely has manually applied migrations; reconcile migration history before using `supabase db push`.
