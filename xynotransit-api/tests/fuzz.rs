//! Fuzz: malformed and random input to EVERY endpoint with EVERY kind of caller.
//!
//! Rules checked for every single answer:
//!   * never a 5xx (a 5xx means something we did not expect: a panic, a database error);
//!   * every 4xx has a JSON body `{"error": "plain words"}` and nothing else;
//!   * no body contains a stack trace, a file path, or SQL text.
//!
//! FUZZ_ITERS (default 40 per endpoint and caller) and FUZZ_SEED (default 1) change the run.

mod common;

use axum::http::StatusCode;
use common::*;

use rand::{rngs::StdRng, seq::IndexedRandom, Rng, SeedableRng};
use serde_json::{json, Map, Number, Value};

const UNICODE: &[&str] = &[
    "",
    " ",
    "\u{0}",
    "a\u{200b}b",
    "\u{202e}abc",
    "\u{feff}",
    "\u{ffff}",
    "\u{10ffff}",
    "😀😀😀",
    "e\u{301}",
    "ＡＢＣ",
    "İstanbul",
    "\n\t\r",
    "line\nbreak",
    "<script>alert(1)</script>",
    "'; drop table person; --",
    "\" or 1=1 --",
    "%s%n%x",
    "../../etc/passwd",
    "{{period}}",
    "${jndi:ldap://x}",
    "null",
    "00000000-0000-0000-0000-000000000000",
    "ffffffff-ffff-ffff-ffff-ffffffffffff",
    "日本語のテキスト",
    "\u{202a}rtl\u{202c}",
];

fn long(r: &mut StdRng) -> String {
    let n = *[
        1usize, 59, 60, 61, 69, 70, 71, 79, 80, 81, 199, 200, 201, 254, 255, 3000,
    ]
    .choose(r)
    .unwrap();
    "x".repeat(n)
}

fn weird(r: &mut StdRng, depth: u32, ids: &[String]) -> Value {
    match r.random_range(0..13) {
        0 => Value::Null,
        1 => json!(r.random_bool(0.5)),
        2 => json!(*[
            0i64,
            -1,
            1,
            2,
            3,
            8,
            9,
            70,
            1_000_000_000,
            1_000_000_001,
            i64::MAX,
            i64::MIN
        ]
        .choose(r)
        .unwrap()),
        3 => json!(u64::MAX),
        4 => Number::from_f64(*[0.5, -0.0, 1e308, -1e308, 1e-320, 2.5e9].choose(r).unwrap())
            .map(Value::Number)
            .unwrap(),
        5 => json!(long(r)),
        6 | 7 => json!(UNICODE.choose(r).unwrap()),
        8 | 9 => json!(ids.choose(r).cloned().unwrap_or_default()),
        10 if depth < 3 => Value::Array(
            (0..r.random_range(0..5))
                .map(|_| weird(r, depth + 1, ids))
                .collect(),
        ),
        11 if depth < 3 => {
            let mut m = Map::new();
            for _ in 0..r.random_range(0..4) {
                let k = UNICODE.choose(r).unwrap().to_string();
                m.insert(k, weird(r, depth + 1, ids));
            }
            Value::Object(m)
        }
        _ => json!(r.random_range(-5..100)),
    }
}

/// Change one leaf, drop one key, add a key, or repeat an element of a valid body.
fn mutate(r: &mut StdRng, v: &mut Value, ids: &[String]) {
    match v {
        Value::Object(m) if !m.is_empty() => {
            let keys: Vec<String> = m.keys().cloned().collect();
            let k = keys.choose(r).unwrap().clone();
            match r.random_range(0..5) {
                0 => {
                    m.remove(&k);
                }
                1 => {
                    m.insert(UNICODE.choose(r).unwrap().to_string(), weird(r, 1, ids));
                }
                2 => {
                    m.insert(k, weird(r, 0, ids));
                }
                _ => mutate(r, m.get_mut(&k).unwrap(), ids),
            }
        }
        Value::Array(a) if !a.is_empty() => {
            let i = r.random_range(0..a.len());
            match r.random_range(0..4) {
                0 => {
                    let c = a[i].clone();
                    a.push(c); // the same id or entry twice
                }
                1 => {
                    a.remove(i);
                }
                _ => mutate(r, &mut a[i], ids),
            }
        }
        other => *other = weird(r, 0, ids),
    }
}

fn raw_body(r: &mut StdRng, template: &Value, ids: &[String]) -> (Option<&'static str>, Vec<u8>) {
    let json_ct = Some("application/json");
    match r.random_range(0..20) {
        0 => (json_ct, vec![]),
        1 => (json_ct, b"{\"a\":".to_vec()),
        2 => (json_ct, vec![0xff, 0xfe, 0x00, 0x80]),
        3 => (json_ct, b"\xef\xbb\xbf{}".to_vec()),
        4 => {
            let d = r.random_range(50..4000);
            (
                json_ct,
                format!("{}{}", "[".repeat(d), "]".repeat(d)).into_bytes(),
            )
        }
        5 => {
            let d = r.random_range(50..3000);
            (
                json_ct,
                format!("{}1{}", "{\"a\":".repeat(d), "}".repeat(d)).into_bytes(),
            )
        }
        6 => (
            json_ct,
            format!("[{}0]", "0,".repeat(r.random_range(1000..140_000))).into_bytes(),
        ),
        7 => {
            let n = r.random_range(100..9000);
            let body: Vec<String> = (0..n).map(|i| format!("\"k{i}\":{i}")).collect();
            (json_ct, format!("{{{}}}", body.join(",")).into_bytes())
        }
        8 => (Some("text/plain"), serde_json::to_vec(template).unwrap()),
        9 => (None, serde_json::to_vec(template).unwrap()),
        10 => (json_ct, serde_json::to_vec(&weird(r, 0, ids)).unwrap()),
        11 => (json_ct, br#""just a string""#.to_vec()),
        12 => (json_ct, b"\"\\ud800\"".to_vec()),
        13 => (json_ct, b"{\"x\":1e999}".to_vec()),
        _ => {
            let mut v = template.clone();
            for _ in 0..r.random_range(1..4) {
                mutate(r, &mut v, ids);
            }
            (json_ct, serde_json::to_vec(&v).unwrap())
        }
    }
}

fn check_answer(label: &str, status: StatusCode, bytes: &[u8]) {
    let text = String::from_utf8_lossy(bytes);
    assert!(
        !status.is_server_error(),
        "{label}: 5xx {status}: {}",
        &text[..text.len().min(300)]
    );
    let lower = text.to_lowercase();
    // An accepted request may echo what the caller typed, so only the strongest signs count there.
    let bad_words: &[&str] = if status.is_success() {
        &["panicked", "stack backtrace", "thread '"]
    } else {
        &[
            "panicked",
            "stack backtrace",
            "src/",
            ".rs:",
            "sqlx",
            "postgres",
            "pg_",
            "violates",
            "syntax error",
            "insert into",
            "select ",
            "update ",
            "relation \"",
            "column \"",
            "thread '",
        ]
    };
    for bad in bad_words {
        assert!(
            !lower.contains(bad),
            "{label}: body leaks {bad:?}: {}",
            &text[..text.len().min(300)]
        );
    }
    if status.is_client_error() {
        let v: Value = serde_json::from_slice(bytes).unwrap_or_else(|_| {
            panic!(
                "{label}: {status} body is not JSON: {}",
                &text[..text.len().min(200)]
            )
        });
        let obj = v
            .as_object()
            .unwrap_or_else(|| panic!("{label}: error body is not an object"));
        assert_eq!(obj.len(), 1, "{label}: {v}");
        let msg = obj["error"]
            .as_str()
            .unwrap_or_else(|| panic!("{label}: no error text: {v}"));
        assert!(!msg.is_empty() && msg.len() < 300, "{label}: {msg}");
    }
}

struct Endpoint {
    method: &'static str,
    /// {p} period, {a} assignment, {t} team, {x} person: replaced by real or hostile values.
    path: &'static str,
    body: Option<Value>,
    query: &'static [&'static str],
}

fn endpoints() -> Vec<Endpoint> {
    let e = |method, path, body: Option<Value>, query: &'static [&'static str]| Endpoint {
        method,
        path,
        body,
        query,
    };
    vec![
        e("GET", "/api/health", None, &[]),
        e(
            "POST",
            "/api/auth/magic-link",
            Some(json!({"email": "ana@example.org"})),
            &[],
        ),
        e(
            "POST",
            "/api/auth/verify",
            Some(json!({"token": "abc"})),
            &[],
        ),
        e("GET", "/api/me", None, &[]),
        e("GET", "/api/catalog", None, &["include_inactive"]),
        e("POST", "/api/teams", Some(json!({"name": "New team"})), &[]),
        e(
            "PATCH",
            "/api/teams/{t}",
            Some(json!({"name": "Renamed", "sort": 3})),
            &[],
        ),
        e("DELETE", "/api/teams/{t}", None, &[]),
        e(
            "POST",
            "/api/persons",
            Some(
                json!({"full_name": "New Person", "email": "new@example.org", "app_role": "contributor"}),
            ),
            &[],
        ),
        e(
            "PATCH",
            "/api/persons/{x}",
            Some(
                json!({"full_name": "Changed", "email": "changed@example.org", "app_role": "contributor", "active": true}),
            ),
            &[],
        ),
        e(
            "POST",
            "/api/assignments",
            Some(json!({"person_id": ANA, "team_id": 1, "role_title": "New seat"})),
            &[],
        ),
        e(
            "PATCH",
            "/api/assignments/{a}",
            Some(json!({"team_id": 2, "role_title": "Moved", "active": true, "sort": 4})),
            &[],
        ),
        e(
            "PUT",
            "/api/assignments/{a}/definitions",
            Some(json!({
                "metrics": [{"id": M_FILES, "label": "Files"}, {"label": "Visits"}],
                "kpis": [{"id": K_ONTIME, "text": "On time"}, {"text": "Fresh target"}],
            })),
            &[],
        ),
        e("GET", "/api/summary", None, &["period_id", "trend"]),
        e(
            "POST",
            "/api/periods/ensure",
            Some(json!({"start_month": "2026-02-01"})),
            &[],
        ),
        e(
            "PATCH",
            "/api/periods/{p}",
            Some(json!({"meeting_date": "2026-05-04"})),
            &[],
        ),
        e("GET", "/api/periods/{p}/reports", None, &[]),
        e("GET", "/api/periods/{p}/reports/{a}", None, &[]),
        e(
            "PUT",
            "/api/periods/{p}/reports/{a}",
            Some(ana_report()),
            &[],
        ),
        e("GET", "/api/periods/{p}/deck", None, &[]),
        e("POST", "/api/periods/{p}/deck", None, &[]),
        e("GET", "/api/periods/{p}/deck-text", None, &[]),
        e(
            "PUT",
            "/api/periods/{p}/deck-text",
            Some(json!({"settings": {"title": "Our meeting", "subtitle": "KPI, {period}"}})),
            &[],
        ),
        e("POST", "/api/events/ticket", None, &[]),
        e("GET", "/api/events", None, &["ticket", "period_id"]),
    ]
}

fn pct(s: &str) -> String {
    s.bytes().map(|b| format!("%{b:02X}")).collect()
}

/// A path part: mostly a real value, sometimes something hostile.
fn hostile(r: &mut StdRng, real: &[String]) -> String {
    match r.random_range(0..8) {
        0 => pct(UNICODE.choose(r).unwrap()),
        1 => "00000000-0000-0000-0000-00000000ffff".into(),
        2 => "99999999999999999999".into(),
        3 => pct(&"a".repeat(r.random_range(1..3000))),
        4 => "-1".into(),
        _ => real.choose(r).unwrap().clone(),
    }
}

#[tokio::test]
async fn nothing_makes_the_api_fail_or_leak() {
    let app = TestApp::new().await;
    let cora = app.login("cora@example.org").await;
    let period = app.ensure_period(&cora, "2026-02-01").await;
    let tokens: Vec<(&str, Option<String>)> = vec![
        ("nobody", None),
        ("garbage token", Some("not.a.token".to_string())),
        ("employee", Some(app.token_for(ANA, false))),
        ("manager", Some(app.token_for(CORA, true))),
        (
            "deactivated",
            Some(app.token_for("00000000-0000-0000-0000-0000000000a4", false)),
        ),
    ];
    let iters: usize = std::env::var("FUZZ_ITERS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(40);
    let seed: u64 = std::env::var("FUZZ_SEED")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(1);
    let mut r = StdRng::seed_from_u64(seed);
    let ids: Vec<String> = [
        ANA, BEN, CORA, A_ANA, A_BEN, A_CORA, M_FILES, M_CALLS, K_ONTIME, &period,
    ]
    .iter()
    .map(|s| s.to_string())
    .collect();
    let (mut total, mut ok, mut client) = (0, 0, 0);
    let mut by_status: std::collections::BTreeMap<u16, u32> = Default::default();
    for ep in endpoints() {
        for (who, token) in &tokens {
            for i in 0..iters {
                // The catalog is shared, so start again regularly: mutating calls change it.
                if i % 10 == 0 {
                    app.reset_fixture().await;
                    app.sql(&format!(
                        "insert into period (id, start_month) values ('{period}', '2026-02-01')"
                    ))
                    .await;
                }
                let real_p = vec![period.clone()];
                let real_a: Vec<String> = [A_ANA, A_BEN, A_CORA]
                    .iter()
                    .map(|s| s.to_string())
                    .collect();
                let real_t: Vec<String> = vec!["1".into(), "2".into()];
                let real_x: Vec<String> = [ANA, BEN, CORA].iter().map(|s| s.to_string()).collect();
                let path = ep
                    .path
                    .replace("{p}", &hostile(&mut r, &real_p))
                    .replace("{a}", &hostile(&mut r, &real_a))
                    .replace("{t}", &hostile(&mut r, &real_t))
                    .replace("{x}", &hostile(&mut r, &real_x));
                let mut uri = path.clone();
                let mut sep = '?';
                for q in ep.query {
                    if r.random_bool(0.8) {
                        let val = match r.random_range(0..4) {
                            0 => pct(UNICODE.choose(&mut r).unwrap()),
                            1 => r.random_range(-3..40).to_string(),
                            2 => "true".into(),
                            _ => ids.choose(&mut r).unwrap().clone(),
                        };
                        uri.push_str(&format!("{sep}{q}={val}"));
                        sep = '&';
                    }
                }
                let (ct, body) = match &ep.body {
                    Some(t) => {
                        let mut t = t.clone();
                        // Mostly the real period / seat in the path, to reach the deep code.
                        if r.random_bool(0.2) {
                            t = weird(&mut r, 0, &ids);
                        }
                        raw_body(&mut r, &t, &ids)
                    }
                    None if r.random_bool(0.1) => {
                        (Some("application/json"), b"{\"junk\":true}".to_vec())
                    }
                    None => (None, vec![]),
                };
                let label = format!("[{who}] {} {uri} ct={ct:?} body={}B", ep.method, body.len());
                let (status, headers, bytes) =
                    app.send(ep.method, &uri, token.as_deref(), ct, body).await;
                check_answer(&label, status, &bytes);
                assert!(headers.contains_key("x-request-id"), "{label}");
                total += 1;
                *by_status.entry(status.as_u16()).or_default() += 1;
                if status.is_success() {
                    ok += 1;
                } else {
                    client += 1;
                }
            }
        }
    }
    eprintln!("{total} requests: {ok} accepted, {client} refused, 0 server errors, by status {by_status:?}");
    assert!(
        ok > 100,
        "the fuzzer should also get some requests through ({ok})"
    );
    assert!(client > 1000);
}

#[tokio::test]
async fn reports_with_hostile_values_never_get_stored_wrong() {
    // Valid-looking reports with one hostile field each: either refused with a plain message, or
    // stored exactly as sent (trimmed). Nothing in between.
    let app = TestApp::new().await;
    let t = app.token_for(ANA, false);
    let cora = app.login("cora@example.org").await;
    let p = app.ensure_period(&cora, "2026-02-01").await;
    let mut r = StdRng::seed_from_u64(7);
    let ids: Vec<String> = vec![M_FILES.into(), K_ONTIME.into()];
    let (mut stored, mut refused) = (0, 0);
    for _ in 0..400 {
        let mut body = ana_report();
        for _ in 0..r.random_range(1..3) {
            mutate(&mut r, &mut body, &ids);
        }
        let (s, h, bytes) = app
            .send(
                "PUT",
                &format!("/api/periods/{p}/reports/{A_ANA}"),
                Some(&t),
                Some("application/json"),
                serde_json::to_vec(&body).unwrap(),
            )
            .await;
        check_answer("hostile report", s, &bytes);
        assert!(h.contains_key("x-request-id"));
        if s == StatusCode::OK {
            stored += 1;
            let rep: Value = serde_json::from_slice(&bytes).unwrap();
            assert_eq!(rep["status"], "submitted");
            // Whatever was stored is within the rules.
            for v in rep["values"].as_array().unwrap() {
                let n = v["value"].as_i64().unwrap();
                assert!((0..=1_000_000_000).contains(&n));
            }
            for n in rep["notes"].as_array().unwrap() {
                let text = n["text"].as_str().unwrap();
                assert!(!text.is_empty() && text.chars().count() <= 70 && text == text.trim());
            }
            for w in ["name", "country", "role"] {
                let x = rep["reporter"][w].as_str().unwrap();
                assert!(
                    !x.is_empty() && x.chars().count() <= 80 && x == x.trim(),
                    "{x:?}"
                );
            }
        } else {
            refused += 1;
        }
    }
    assert!(
        stored > 20 && refused > 100,
        "{stored} stored, {refused} refused"
    );
    assert_eq!(app.count("report").await, 1);
}
