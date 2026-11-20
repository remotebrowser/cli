# Remote Browser CLI

`remotebrowser` is a command-line tool for the [Remote Browser REST API](https://remotebrowser.ai/api/).

## Usage

The tool reads the API key and the base URL from the environment:

```bash
export REMOTEBROWSER_API_KEY=sk-rb-v1-...
export REMOTEBROWSER_URL=https://remotebrowser.example
```

```bash
ID=$(remotebrowser create --os ubuntu-26.04 --browser chrome --wait)
remotebrowser list
remotebrowser get $ID
remotebrowser connect $ID      # prints the CDP WebSocket URL
remotebrowser suspend $ID
remotebrowser resume $ID
remotebrowser config set $ID --proxy socks5://proxy.example:1080
remotebrowser config get $ID
remotebrowser delete $ID
```

| Command                              | Description                                        |
| ------------------------------------ | -------------------------------------------------- |
| `create [options]`                   | Launch a browser and print its id                  |
| `list` (`ls`)                        | Print the ids of the starting and running browsers |
| `get <id>` (`info`)                  | Show the details of a browser                      |
| `delete <id>...` (`rm`)              | Terminate browsers                                 |
| `suspend <id>...` / `resume <id>...` | Suspend or resume browsers                         |
| `connect <id>`                       | Print the CDP WebSocket URL                        |
| `config get <id>`                    | Show the configuration                             |
| `config set <id> --proxy <url>`      | Change the proxy                                   |
| `config set <id> --no-proxy`         | Remove the proxy                                   |

`create` takes `--name`, `--description`, `--os`, `--browser`, `--screen-resolution`, `--screen-scale`, `--proxy`, and `--wait` (wait until the browser is running). Options you leave out use the server's defaults. Every command takes `--json` to print the raw API response. Run `remotebrowser --help`, or `remotebrowser <command> --help`, for details.

The CDP endpoint needs the API key in the `Authorization: Bearer` header. For example, with Playwright for Python:

```python
browser = p.chromium.connect_over_cdp(cdp_url, headers={"Authorization": f"Bearer {api_key}"})
```

### Exit codes

The exit code is 0 on success, 1 when the API call fails, and 2 for a usage error. An API failure prints the status code and the server's message, such as `remotebrowser: 409 Only a suspended browser can be resumed.`

When `delete`, `suspend`, or `resume` gets several ids, it continues after a failure and exits with 1 at the end.

### Retries and timeouts

Connection errors and 408, 429, and 5xx responses are retried up to 2 times, with exponential backoff, and the `Retry-After` header is respected. 409 is not retried, because it means the browser is in the wrong state. Each attempt times out after 60 seconds without a response.
