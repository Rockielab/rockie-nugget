from pathlib import Path

import yaml


REPO_ROOT = Path(__file__).resolve().parents[1]
ATTRIBUTION_PATH = REPO_ROOT / "overlay" / "ATTRIBUTION.yaml"

FORBIDDEN_KEYS = {
    "agent_run_id",
    "api_key",
    "bearer_token",
    "credential_row_id",
    "email",
    "internal_tenant_id",
    "internal_user_id",
    "moderation_internal",
    "nonce",
    "oauth_token",
    "phone",
    "private_contact",
    "proposal_id",
    "proposal_record",
    "raw_proposal",
    "raw_vote",
    "rejected_proposal",
    "review_comment",
    "token",
    "verification_challenge",
    "voter_identity",
    "withdrawn_proposal",
}


def load_manifest():
    with ATTRIBUTION_PATH.open() as handle:
        return yaml.safe_load(handle)


def walk_keys(value):
    if isinstance(value, dict):
        for key, nested in value.items():
            yield str(key)
            yield from walk_keys(nested)
    elif isinstance(value, list):
        for item in value:
            yield from walk_keys(item)


def assert_complete_attribution(attribution):
    assert isinstance(attribution, dict)
    assert attribution["schema_version"] == 1
    assert attribution["authors"]
    assert attribution["maintainers"]
    assert attribution["profiles"]
    assert attribution["source"]
    assert attribution["contact_policy"]
    assert attribution["completeness"] == "complete"

    profiles = attribution["profiles"]
    for role in ("authors", "maintainers"):
        for person in attribution[role]:
            assert person["rockie_username"]
            assert person["display_name"]
            assert person["profile_refs"]
            for profile_ref in person["profile_refs"]:
                assert profile_ref in profiles


def test_overlay_attribution_manifest_is_parseable_and_complete():
    manifest = load_manifest()

    assert manifest["surface"] == "rockie-nugget-overlay"
    assert_complete_attribution(manifest["attribution"])
    assert manifest["attribution"]["source"]["repo"] == "Rockielab/rockie-nugget"
    assert manifest["attribution"]["source"]["path"] == "overlay/ATTRIBUTION.yaml"


def test_upstream_skill_attributions_are_complete_without_skill_mirrors():
    manifest = load_manifest()
    upstream = manifest["upstream_skill_attributions"]

    assert "does not ship direct SKILL.md mirrors" in upstream["note"]
    assert {entry["name"] for entry in upstream["skills"]} == {
        "build-agent",
        "diligence-deck",
        "excel",
        "physics",
        "powerpoint",
        "upstream-contribute",
    }
    for entry in upstream["skills"]:
        assert_complete_attribution(entry["attribution"])


def test_overlay_attribution_contains_no_forbidden_private_or_product_keys():
    keys = {key.lower() for key in walk_keys(load_manifest())}

    assert keys.isdisjoint(FORBIDDEN_KEYS)
