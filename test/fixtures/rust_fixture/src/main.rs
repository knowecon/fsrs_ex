//! Parity fixture generator for fsrs_ex.
//!
//! Calls the public inference API of the `fsrs` crate and dumps inputs and
//! outputs as JSON. Usage:
//!
//!     cargo run --release -- ../fsrs_rs_v7_0_0_fixture.json
//!     gzip -9nf ../fsrs_rs_v7_0_0_fixture.json

use fsrs::{
    check_and_fill_parameters, current_retrievability, FSRSItem, FSRSReview, MemoryState,
    ModelVersion, DEFAULT_PARAMETERS, FSRS, FSRS5_DEFAULT_DECAY, FSRS6_DEFAULT_DECAY,
    FSRS6_DEFAULT_PARAMETERS,
};
use serde_json::{json, Value};

const FSRS_RS_VERSION: &str = "7.0.0";

/// Deterministic generator so the fixture is reproducible.
struct Lcg(u64);

impl Lcg {
    fn next_u32(&mut self) -> u32 {
        self.0 = self
            .0
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        (self.0 >> 33) as u32
    }

    fn pick<T: Copy>(&mut self, items: &[T]) -> T {
        items[(self.next_u32() as usize) % items.len()]
    }
}

/// Rewrites every float as the shortest decimal that round-trips through
/// `f32`, e.g. `0.9` instead of `0.8999999761581421`. All floats here come
/// from `f32` values, and a caller of fsrs_ex writes `0.9`, not the widened
/// `f32`.
fn shorten_floats(value: &mut Value) {
    match value {
        Value::Number(number) if number.is_f64() => {
            let short: f64 = (number.as_f64().unwrap() as f32).to_string().parse().unwrap();
            *value = json!(short);
        }
        Value::Array(items) => items.iter_mut().for_each(shorten_floats),
        Value::Object(map) => map.values_mut().for_each(shorten_floats),
        _ => {}
    }
}

fn state_json(state: MemoryState) -> Value {
    json!({
        "stability": state.stability,
        "difficulty": state.difficulty,
        "stability_fast": state.stability_fast,
    })
}

fn opt_state_json(state: Option<MemoryState>) -> Value {
    state.map(state_json).unwrap_or(Value::Null)
}

fn reviews_json(reviews: &[FSRSReview]) -> Value {
    Value::Array(
        reviews
            .iter()
            .map(|r| json!({"rating": r.rating, "delta_t": r.delta_t}))
            .collect(),
    )
}

fn version_name(version: ModelVersion) -> &'static str {
    match version {
        ModelVersion::Fsrs6 => "fsrs6",
        ModelVersion::Fsrs7 => "fsrs7",
    }
}

fn result_json<T>(result: fsrs::Result<T>, ok: impl Fn(T) -> Value) -> Value {
    match result {
        Ok(value) => json!({"ok": ok(value)}),
        Err(err) => json!({"error": format!("{err:?}")}),
    }
}

fn next_states_json(states: fsrs::NextStates) -> Value {
    let item = |s: fsrs::ItemState| json!({"memory": state_json(s.memory), "interval": s.interval});
    json!({
        "again": item(states.again),
        "hard": item(states.hard),
        "good": item(states.good),
        "easy": item(states.easy),
    })
}

fn sample_states() -> Vec<MemoryState> {
    let difficulties = [1.0, 3.3, 5.0, 7.25, 10.0];
    let mut states = Vec::new();
    for (index, (stability, fast_ratio)) in [
        (0.0001, 1.0),
        (0.003, 0.8),
        (0.05, 0.5),
        (0.4, 1.3),
        (1.0, 0.8),
        (3.9221, 0.8),
        (12.0, 0.8),
        (12.0, 0.2),
        (75.5, 1.0),
        (400.0, 0.6),
        (3000.0, 0.8),
        (36500.0, 1.0),
    ]
    .into_iter()
    .enumerate()
    {
        for offset in [0, 2] {
            states.push(MemoryState {
                stability,
                difficulty: difficulties[(index + offset) % difficulties.len()],
                stability_fast: stability * fast_ratio,
            });
        }
    }
    states
}

fn sample_histories() -> Vec<Vec<FSRSReview>> {
    let r = |rating: u32, delta_t: f32| FSRSReview { rating, delta_t };
    vec![
        vec![],
        vec![r(1, 0.0)],
        vec![r(2, 0.0)],
        vec![r(3, 0.0)],
        vec![r(4, 0.0)],
        vec![r(3, 0.0), r(3, 1.0), r(3, 3.0), r(3, 8.0), r(3, 21.0)],
        vec![r(1, 0.0), r(3, 0.0), r(3, 1.0), r(1, 4.0), r(3, 0.0), r(3, 2.0)],
        vec![r(3, 0.0), r(2, 0.007), r(3, 0.25), r(4, 0.6), r(1, 2.4), r(3, 0.004)],
        vec![r(4, 0.0), r(4, 10.0), r(4, 60.0), r(4, 400.0), r(1, 2000.0), r(3, 1.0)],
        vec![r(1, 0.0), r(1, 0.0), r(1, 0.0), r(1, 1.0), r(1, 1.0), r(2, 1.0)],
        vec![r(3, 0.0), r(0, 5.0), r(3, 5.0), r(7, 5.0)],
        vec![r(0, 0.0), r(3, 2.0)],
        vec![r(2, 0.0), r(2, 1.49), r(2, 1.51), r(3, 0.49), r(3, 0.51)],
    ]
}

fn model_cases(name: &str, parameters: &[f32]) -> Value {
    let fsrs = FSRS::new(parameters).unwrap();
    let states = sample_states();
    let retentions = [0.7f32, 0.85, 0.9, 0.95, 0.99];
    let elapsed = [0.0f32, 0.0007, 0.02, 0.4, 0.5, 1.0, 1.5, 3.7, 30.0, 365.0, 5000.0];

    let mut retrievability = Vec::new();
    let mut intervals = Vec::new();
    for state in &states {
        for &days in &elapsed {
            retrievability.push(json!({
                "state": state_json(*state),
                "days_elapsed": days,
                "result": fsrs.current_retrievability(*state, days),
            }));
        }
        retrievability.push(json!({
            "state": state_json(*state),
            "days_elapsed": -3.0,
            "result": fsrs.current_retrievability(*state, -3.0),
        }));
        for target in [0.00001f32, 0.5, 0.7, 0.85, 0.9, 0.95, 0.99, 0.9999, 1.0] {
            intervals.push(json!({
                "state": state_json(*state),
                "target": target,
                "interval_at_retrievability": fsrs.interval_at_retrievability(*state, target),
                "next_interval_for_state": fsrs.next_interval_for_state(*state, target),
            }));
        }
    }

    let s90: Vec<Value> = states
        .iter()
        .map(|state| json!({"state": state_json(*state), "result": fsrs.s90(*state)}))
        .collect();

    let mut next_interval = Vec::new();
    for stability in [None, Some(0.0001f32), Some(0.5), Some(7.0), Some(121.01552), Some(36500.0)] {
        for &retention in &retentions {
            for rating in [0u32, 1, 2, 3, 4, 9] {
                next_interval.push(json!({
                    "stability": stability,
                    "desired_retention": retention,
                    "rating": rating,
                    "result": fsrs.next_interval(stability, retention, rating),
                }));
            }
        }
    }

    let mut next_states = Vec::new();
    for &retention in &retentions {
        for days in [0u32, 1, 7] {
            next_states.push(json!({
                "state": Value::Null,
                "desired_retention": retention,
                "days_elapsed": days,
                "integer_days": true,
                "result": result_json(fsrs.next_states(None, retention, days), next_states_json),
            }));
        }
    }
    for (index, state) in states.iter().enumerate() {
        for (offset, &days) in elapsed.iter().enumerate().skip(index % 2).step_by(2) {
            let retention = retentions[(index + offset) % retentions.len()];
            next_states.push(json!({
                "state": state_json(*state),
                "desired_retention": retention,
                "days_elapsed": days,
                "integer_days": false,
                "result": result_json(
                    fsrs.next_states_with_elapsed_days(Some(*state), retention, days),
                    next_states_json,
                ),
            }));
        }
    }
    // A zero-stability state passed explicitly is not treated as a new card.
    let zero = MemoryState { stability: 0.0, difficulty: 0.0, stability_fast: 0.0 };
    next_states.push(json!({
        "state": state_json(zero),
        "desired_retention": 0.9,
        "days_elapsed": 2.0,
        "integer_days": false,
        "result": result_json(
            fsrs.next_states_with_elapsed_days(Some(zero), 0.9, 2.0),
            next_states_json,
        ),
    }));

    let starting = MemoryState { stability: 20.0, difficulty: 6.0, stability_fast: 9.0 };
    let mut memory_state = Vec::new();
    for reviews in sample_histories() {
        for starting_state in [None, Some(starting), Some(zero)] {
            let item = FSRSItem { reviews: reviews.clone() };
            memory_state.push(json!({
                "reviews": reviews_json(&reviews),
                "starting_state": opt_state_json(starting_state),
                "memory_state": result_json(
                    fsrs.memory_state(item.clone(), starting_state),
                    state_json,
                ),
                "historical_memory_states": result_json(
                    fsrs.historical_memory_states(item, starting_state),
                    |states| Value::Array(states.into_iter().map(state_json).collect()),
                ),
            }));
        }
    }

    let mut sm2 = Vec::new();
    for ease_factor in [1.3f32, 2.5, 3.1] {
        for interval in [0.0f32, 0.5, 1.0, 30.0, 100.0, 5000.0, 99999.0] {
            for retention in [-0.1f32, 0.0, 0.3, 0.8, 0.9, 0.95, 0.999, 1.0, 1.2] {
                sm2.push(json!({
                    "ease_factor": ease_factor,
                    "interval": interval,
                    "sm2_retention": retention,
                    "result": result_json(
                        fsrs.memory_state_from_sm2(ease_factor, interval, retention),
                        state_json,
                    ),
                }));
            }
        }
    }

    // Long simulated walk: feed each chosen next state back in, so the trace
    // visits extreme stabilities and difficulties.
    let mut walks = Vec::new();
    for seed in [1u64, 2] {
        let mut rng = Lcg(seed);
        let mut state: Option<MemoryState> = None;
        let mut steps = Vec::new();
        for _ in 0..100 {
            let retention = rng.pick(&retentions);
            let days = if state.is_none() {
                0.0
            } else {
                rng.pick(&[0.0f32, 0.001, 0.01, 0.3, 1.0, 2.0, 6.5, 19.0, 80.0, 700.0])
            };
            let rating = rng.pick(&[1u32, 2, 3, 3, 3, 4, 1, 3]);
            let next = fsrs
                .next_states_with_elapsed_days(state, retention, days)
                .unwrap();
            let chosen = match rating {
                1 => next.again.clone(),
                2 => next.hard.clone(),
                3 => next.good.clone(),
                _ => next.easy.clone(),
            };
            steps.push(json!({
                "state": opt_state_json(state),
                "desired_retention": retention,
                "days_elapsed": days,
                "rating": rating,
                "next_states": next_states_json(next),
            }));
            state = Some(chosen.memory);
        }
        walks.push(json!({"seed": seed, "steps": steps}));
    }

    json!({
        "name": name,
        "parameters": parameters,
        "version": version_name(fsrs.version()),
        "current_retrievability": retrievability,
        "intervals": intervals,
        "s90": s90,
        "next_interval": next_interval,
        "next_states": next_states,
        "memory_state": memory_state,
        "memory_state_from_sm2": sm2,
        "walks": walks,
    })
}

fn main() {
    let mut custom_v7 = DEFAULT_PARAMETERS;
    custom_v7[23] = 0.3; // clipped to 0.25
    custom_v7[27] = 0.7;
    custom_v7[29] = 0.2;
    custom_v7[30] = 0.8;
    custom_v7[25] = 0.7;
    custom_v7[26] = 0.6; // clipped up to w25
    custom_v7[2] = 1.0; // clipped up to w1
    custom_v7[6] = 0.01;

    let mut custom_v6 = FSRS6_DEFAULT_PARAMETERS;
    custom_v6[0] = 0.00001;
    custom_v6[7] = 0.9;
    custom_v6[17] = 3.0;
    custom_v6[19] = 0.0;
    custom_v6[20] = 0.05;

    let fsrs45: [f32; 17] = [
        0.4872, 1.4003, 3.7145, 13.8206, 5.1618, 1.2298, 0.8975, 0.031, 1.6474, 0.1367, 1.0461,
        2.1072, 0.0793, 0.3246, 1.587, 0.2272, 2.8755,
    ];
    let fsrs5: [f32; 19] = [
        0.40255, 1.18385, 3.173, 15.69105, 7.1949, 0.5345, 1.4604, 0.0046, 1.54575, 0.1192,
        1.01925, 1.9395, 0.11, 0.29605, 2.2698, 0.2315, 2.9898, 0.51655, 0.6621,
    ];

    let models = vec![
        model_cases("fsrs7_default", &DEFAULT_PARAMETERS),
        model_cases("fsrs7_custom", &custom_v7),
        model_cases("fsrs6_default", &FSRS6_DEFAULT_PARAMETERS),
        model_cases("fsrs6_custom", &custom_v6),
        model_cases("fsrs5_19", &fsrs5),
        model_cases("fsrs45_17", &fsrs45),
    ];

    let mut check_and_fill = Vec::new();
    let mut inputs: Vec<Vec<f32>> = vec![
        vec![],
        DEFAULT_PARAMETERS.to_vec(),
        custom_v7.to_vec(),
        FSRS6_DEFAULT_PARAMETERS.to_vec(),
        fsrs5.to_vec(),
        fsrs45.to_vec(),
    ];
    for count in [1usize, 16, 18, 20, 22, 33, 35] {
        inputs.push(vec![1.0; count]);
    }
    for input in inputs {
        check_and_fill.push(json!({
            "input": input,
            "result": result_json(check_and_fill_parameters(&input), |p| json!(p)),
            "new": result_json(FSRS::new(&input), |f| json!(version_name(f.version()))),
        }));
    }

    let mut free_retrievability = Vec::new();
    for state in sample_states().into_iter().step_by(5) {
        for days in [0.0f32, 0.3, 1.0, 12.5, 400.0] {
            for decay in [FSRS5_DEFAULT_DECAY, FSRS6_DEFAULT_DECAY, 0.3] {
                free_retrievability.push(json!({
                    "state": state_json(state),
                    "days_elapsed": days,
                    "decay": decay,
                    "result": current_retrievability(state, days, decay),
                }));
            }
        }
    }

    // `FSRS::default()` and empty parameters select the FSRS-7 defaults.
    let default_model = json!({
        "version": version_name(FSRS::default().version()),
        "next_states": next_states_json(FSRS::default().next_states(None, 0.9, 0).unwrap()),
        "empty_parameters_next_states":
            next_states_json(FSRS::new(&[]).unwrap().next_states(None, 0.9, 0).unwrap()),
    });

    let mut fixture = json!({
        "meta": {"fsrs_rs_version": FSRS_RS_VERSION},
        "default_parameters": DEFAULT_PARAMETERS.to_vec(),
        "fsrs6_default_parameters": FSRS6_DEFAULT_PARAMETERS.to_vec(),
        "fsrs5_default_decay": FSRS5_DEFAULT_DECAY,
        "fsrs6_default_decay": FSRS6_DEFAULT_DECAY,
        "check_and_fill_parameters": check_and_fill,
        "default_model": default_model,
        "current_retrievability_with_decay": free_retrievability,
        "models": models,
    });

    shorten_floats(&mut fixture);
    let output = serde_json::to_string(&fixture).unwrap();
    match std::env::args().nth(1) {
        Some(path) => std::fs::write(path, output + "\n").unwrap(),
        None => println!("{output}"),
    }
}
