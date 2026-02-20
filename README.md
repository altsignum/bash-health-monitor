# Health Monitor

Health Monitor is a lightweight systemd-based service health dashboard
implemented as a Bash HTTP server with socket activation.

It provides real-time health status for selected systemd units,
analyzes journal logs since last activation, and exposes a minimal JSON API
for integration or aggregation across multiple nodes.

Designed for Debian-based Linux systems with:
- systemd
- journalctl
- iproute2
- bash

The server uses systemd socket activation and does not require
a separate web server or runtime environment.

## Monitored Service Requirements

* Must be a `systemd` service  
   The service must be available via:

    ```
    systemctl status <service>
    ```

* Must log errors in the supported format  
    Errors are detected from journal logs since last activation.
    Required log format:
    ```
    YYYY-MM-DD HH:MM:SS(.fraction)|LEVEL|Message
    ```
    `LEVEL` must be:
    - `ERROR`
    - `FATAL`

* Error counting resets after service restart  
    Health is calculated from the last activation time.

## Status Classification

- `failed` — systemd reports failed  
- `stopped` — not active  
- `completed` — exited successfully  
- `transition` — not running but not failed  
- `stable` — running, no errors since last activation  
- `unstable` — running, errors detected since last activation  

## API
Base URL: http://{host}:{port}

* GET /  
    Returns `index.html` if present.

* GET /services  
    Returns the list of monitored services.  
    Response example:
    ```json
    ["nginx", "app"]
    ```

* GET /monitors  
    Returns the list of external Health Monitor URLs.  
    Response example:
    ```json
    ["http://10.0.0.5:60100"]
    ```

* GET /host  
    Returns the resolved external IPv4 address of the current machine.  
    The value is determined by analyzing the active network interface.  
    Response example:
    ```json
    {
        "host": "203.0.113.25"
    }
    ```

* GET /status?service={name}  
    Returns health status of a service.
    Response example:
    ```json
    {
        "status": "stopped",
        "host": "203.0.113.25"
    }
    ```
    ```json
    {
        "status": "stable",
        "activeSince": "Wed 2026-01-15 14:23:41 UTC",
        "host": "203.0.113.25"
    }
    ```
    ```json
    {
        "status": "unstable",
        "errorCount": 10,
        "activeSince": "Wed 2026-01-15 14:23:41 UTC",
        "host": "203.0.113.25"
    }
    ```

* GET /all  
    Returns aggregated health status of the current Health Monitor instance,
    including:
    - `services` — statuses of local monitored systemd services
    - `monitors` — recursive results from external Health Monitor instances

    The response structure is recursive: each monitor entry has the same
    shape as the root payload.

    Response example:
    ```json
    {
        "name": null,
        "services": [
            {
                "name": "nginx",
                "status": "stable",
                "activeSince": "2026-02-20T02:12:28Z",
                "host": "203.0.113.25"
            }
        ],
        "monitors": [
            {
                "name": "http://203.0.113.26:60100",
                "services": [
                    {
                        "name": "server",
                        "status": "stable",
                        "activeSince": "2026-02-18T06:12:59Z",
                        "host": "203.0.113.26"
                    }
                ],
                "monitors": []
            }
        ]
    }
    ```

* GET /errors?service={name}[&format=text]  
    Returns error log blocks (`ERROR`, `FATAL`) since last activation.  
    - `format` — response format:
        - `json` (default) — JSON array of log blocks
        - `text` — plain text stream (recommended for large outputs)
    Response example:
    ```json
    [
        "2026-02-17 08:29:06.2641|ERROR|Database failed",
        "2026-02-17 08:30:10.1001|FATAL|Crash detected"
    ]
    ```
    Response example (`format=text`):
    ```text
    2026-02-17 08:29:06.2641|ERROR|Database failed


    2026-02-17 08:30:10.1001|FATAL|Crash detected
    ```

### Proxy mode (monitor={url})

All API endpoints except `/` support optional query parameter `monitor`.
If `monitor` is provided, the request is proxied through the current
Health Monitor instance to the remote Health Monitor and the remote
response is returned as-is.

This is used by the UI to avoid cross-origin requests.

Examples:

* Get remote monitored services:
    ```text
    GET /list?monitor=http%3A%2F%2F10.0.0.5%3A60100
    ```

* Get remote host:
    ```text
    GET /host?monitor=http%3A%2F%2F10.0.0.5%3A60100
    ```

* Get remote service status:
    ```text
    GET /status?service=nginx&monitor=http%3A%2F%2F10.0.0.5%3A60100
    ```

* Get remote service errors:
    ```text
    GET /errors?service=nginx&monitor=http%3A%2F%2F10.0.0.5%3A60100
    ```

Notes:
- `monitor` must be URL-encoded.
- Remote `service` name is passed through unchanged.

## Install

1. Create target directory:

    ```bash
    sudo mkdir -p /var/www/health
    ```

2. Copy the contents of the repository [src/](src/) directory
   (uploaded manually, via scp, rsync, archive, etc.) into `/var/www/health`

3. Make the entry script executable:

    ```bash
    sudo chmod +x /var/www/health/health.sh
    ```

4. Configure monitoring lists:

    Edit the following files inside:

    ```
    /var/www/health
    ```

    - `services.list` — add systemd unit names that must be monitored  
    (one unit per line, for example: `nginx.service`)

    - `monitors.list` — add URLs of other Health Monitor instances  
    (one URL per line, for example: `http://10.0.0.5:60100`)

5. Place the repository files:  
    [systemd/health@.service](systemd/health@.service)  
    [systemd/health.socket](systemd/health.socket)  

    into:

    ```
    /etc/systemd/system/
    ```

6. Reload systemd and enable socket (autostart on boot):

    ```bash
    sudo systemctl daemon-reload
    sudo systemctl enable --now health.socket
    ```

    `health.socket` uses socket activation and starts `health@.service` per connection.
