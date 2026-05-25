# ==========================================================================
# TradeForge — self-hosted Supabase-style stack (PostgREST + Realtime)
# ==========================================================================
# Unlike every other OIDC app here (RS256 via the shared signing_key), TradeForge
# must use HS256 signed with the shared JWT_SECRET. That single symmetric key has
# to validate BOTH Authentik user tokens AND the static anon/service_role keys
# that PostgREST and Realtime rely on, so they cannot be RS256/JWKS.
#
# How HS256 is achieved: omit `signing_key`. Authentik then signs tokens with the
# provider's client_secret, which we set to the JWT_SECRET from 1Password (the
# same value configured as PGRST_JWT_SECRET / Realtime API_JWT_SECRET in the
# cluster). The client is `public` (browser SPA, PKCE) — the secret is only used
# server-side by Authentik for signing and is never sent to the browser.
#
# PostgREST switches DB roles from the JWT `role` claim, so a custom scope mapping
# injects `role: authenticated`. The SPA must request the `tradeforge` scope for
# that claim to be included (VITE_OIDC scopes: "openid email profile tradeforge").
#
# 1Password item `tradeforge` (vault Kubernetes) must provide:
#   - oidc_client_id : the OAuth client_id (also the SPA's VITE_OIDC_CLIENT_ID)
#   - JWT_SECRET     : the shared HS256 secret (already present)

module "onepassword_tradeforge" {
  source = "github.com/pipitonelabs/terraform-1password-item"
  vault  = "Kubernetes"
  item   = "tradeforge"
}

# Adds the PostgREST role claim. Delivered when the client requests `tradeforge`.
resource "authentik_property_mapping_provider_scope" "tradeforge_role" {
  name        = "tradeforge-role"
  scope_name  = "tradeforge"
  description = "Injects the PostgREST role claim for TradeForge tokens"
  expression  = <<-EOT
    return {
        "role": "authenticated",
    }
  EOT
}

resource "authentik_provider_oauth2" "tradeforge" {
  name                = "tradeforge"
  client_type         = "public"
  client_id           = module.onepassword_tradeforge.fields["oidc_client_id"]
  client_secret       = module.onepassword_tradeforge.fields["JWT_SECRET"]
  authorization_flow  = authentik_flow.provider-authorization-implicit-consent.uuid
  authentication_flow = authentik_flow.authentication.uuid
  invalidation_flow   = authentik_flow.invalidation.uuid

  # No signing_key => HS256 signed with client_secret (= JWT_SECRET).
  sub_mode              = "user_uuid" # stable sub; becomes profiles.id in the app
  access_token_validity = "hours=4"

  property_mappings = concat(
    data.authentik_property_mapping_provider_scope.oauth2.ids,
    [authentik_property_mapping_provider_scope.tradeforge_role.id],
  )

  allowed_redirect_uris = [
    {
      matching_mode = "strict"
      url           = "https://tradeforge-new.${var.CLUSTER_DOMAIN}/auth/callback"
    },
    {
      matching_mode = "strict"
      url           = "https://tradeforge.${var.CLUSTER_DOMAIN}/auth/callback"
    },
  ]
}

resource "authentik_application" "tradeforge" {
  name               = "TradeForge"
  slug               = "tradeforge"
  protocol_provider  = authentik_provider_oauth2.tradeforge.id
  group              = authentik_group.default["self-hosted"].name
  meta_launch_url    = "https://tradeforge.${var.CLUSTER_DOMAIN}/"
  open_in_new_tab    = true
  policy_engine_mode = "all"
}

resource "authentik_policy_binding" "tradeforge" {
  target = authentik_application.tradeforge.uuid
  group  = authentik_group.default["self-hosted"].id
  order  = 0
}
