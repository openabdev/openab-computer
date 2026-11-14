//! The attach secret is kept on the node so a grant can resume after a restart
//! (#12). It must never appear in the grant body that `GET /attach` and
//! `GET /attach/{id}` return. The Swift oracle is
//! `AttachCredentialSecrecyTests`.

use super::*;

const CANARY: &str = "CANARY-SECRET-7f3a";

#[test]
fn grant_json_never_carries_the_attach_secret() {
    for ended in [None, Some("revoked".to_string())] {
        let g = GrantInfo {
            id: "grant-1-1".to_string(),
            runtime: "ws://198.51.100.2:8090".to_string(),
            session: "s1".to_string(),
            profile: "owner".to_string(),
            requested_profile: "owner".to_string(),
            warning: None,
            principal: "a@b".to_string(),
            state: "attached".to_string(),
            ended,
            expires_at_epoch_secs: now_epoch_secs() + 600,
            cancelled: Arc::new(AtomicBool::new(false)),
            secret: CANARY.to_string(),
        };
        let body = grant_json(&g);
        assert!(
            !body.to_string().contains(CANARY),
            "attach secret leaked into the grant body: {body}"
        );
        assert!(
            body.get("secret").is_none(),
            "grant body has a secret key: {body}"
        );
    }
}
