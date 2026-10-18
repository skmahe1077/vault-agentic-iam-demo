# Required only because the IBM Passport Advantage-issued license
# (vault_techxchange_*.hclic) doesn't carry its entitlements the way a
# standard HashiCorp-issued Enterprise license does -- Vault has to be told
# explicitly which edition it's entitled to, or it rejects the license with
# "invalid module". No add_ons needed (KMIP etc. aren't used by this demo).
license_entitlement {
  edition = "platform-standard"
}
