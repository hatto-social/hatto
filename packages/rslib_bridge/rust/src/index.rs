include!(concat!(env!("OUT_DIR"), "/service_index.rs"));

pub fn lookup(service: &str, method: &str) -> Option<(u32, u32)> {
    SERVICE_METHODS
        .iter()
        .find(|entry| entry.service == service && entry.method == method)
        .map(|entry| (entry.service_index, entry.method_index))
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
