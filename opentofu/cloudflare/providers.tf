# Auth comes from the CLOUDFLARE_API_TOKEN env var. The token must
# carry enough scope to manage the entire opennutritracker.org zone
# (DNS, cache rules, custom domains) and any R2 bucket on the
# account, plus permission to mint and revoke other API tokens —
# this OpenTofu config generates downstream tokens for the workflow
# rather than having anyone create them by hand.
provider "cloudflare" {}

# Auth comes from the GITHUB_TOKEN env var. The token needs `repo`
# scope on simonoppowa/OpenNutriTracker (or whichever repo the
# workflow lives in) so OpenTofu can write Actions secrets.
provider "github" {
  owner = var.github_owner
}
