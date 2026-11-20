// SPDX-FileCopyrightText: 2026 Hatto Social contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

include!(concat!(env!("OUT_DIR"), "/service_index.rs"));

pub fn lookup(service: &str, method: &str) -> Option<(u32, u32)> {
    SERVICE_METHODS
        .iter()
        .find(|entry| entry.service == service && entry.method == method)
        .map(|entry| (entry.service_index, entry.method_index))
}

/// Index back to the protobuf service and snake_case method.
///
/// `command` uses this so a desktop profile can allow or deny by name.
/// Numbers are not an ABI: a pin change that drops a name fails the tests
/// that resolve the allowlist through [lookup].
pub fn reverse(service: u32, method: u32) -> Option<(&'static str, &'static str)> {
    SERVICE_METHODS
        .iter()
        .find(|entry| entry.service_index == service && entry.method_index == method)
        .map(|entry| (entry.service, entry.method))
}

pub fn iter_methods() -> impl Iterator<Item = &'static ServiceMethod> {
    SERVICE_METHODS.iter()
}

pub fn describe_service(service: &str) -> String {
    let mut names: Vec<&str> = SERVICE_METHODS
        .iter()
        .filter(|entry| entry.service == service)
        .map(|entry| entry.method)
        .collect();
    names.sort_unstable();
    if names.is_empty() {
        let mut services: Vec<&str> = SERVICE_METHODS.iter().map(|entry| entry.service).collect();
        services.sort_unstable();
        services.dedup();
        format!("unknown service {service}; known={services:?}")
    } else {
        format!("methods on {service}: {names:?}")
    }
}
