# Remote Browser CLI

`remotebrowser` is a command-line tool for the [Remote Browser REST API](https://remotebrowser.ai/api/).

Log in once to each server with a web browser:

```bash
remotebrowser login https://rb.example.com
```

The CLI shows a code and opens the approval page of the server. Check that the page shows the same
code, approve it, and the CLI saves a token. Use `--no-browser` to only print the URL of the page,
for example over SSH or in a container.

You can log in to several servers. Commands use the current server, which is the last one you
logged in to or chose with `switch`, and `list` takes a server as its argument:

```bash
remotebrowser status                          # list the logins; * marks the one in use
remotebrowser switch https://rb.example.com   # choose the current server
remotebrowser list http://10.0.0.5:8080       # list the browsers on another server
remotebrowser logout                          # log out of the current server
remotebrowser logout http://10.0.0.5:8080     # log out of another server
```

`logout` revokes the token on the server and deletes it from this computer.

## Usage

```bash
remotebrowser login https://rb.example.com
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

| Command                              | Description                                 |
| ------------------------------------ | ------------------------------------------- |
| `login [url]`                        | Log in with a web browser                   |
| `logout [url]`                       | Revoke the login and delete it              |
| `status`                             | List the logins and show which one is used  |
| `switch <url>`                       | Choose the current server                   |
| `create [options]`                   | Launch a browser and print its id           |
| `list [url]` (`ls`)                  | Print the ids of the active browsers        |
| `get <id>` (`info`)                  | Show the details of a browser               |
| `delete <id>...` (`rm`)              | Terminate browsers                          |
| `suspend <id>...` / `resume <id>...` | Suspend or resume browsers                  |
| `connect <id>`                       | Print the CDP WebSocket URL                 |
| `token`                              | Print the login token, for the CDP header   |
| `config get <id>`                    | Show the configuration                      |
| `config set <id> --proxy <url>`      | Change the proxy                            |
| `config set <id> --no-proxy`         | Remove the proxy                            |

`create` takes `--name`, `--description`, `--os`, `--browser`, `--screen-resolution`, `--screen-scale`, `--proxy`, and `--wait` (wait until the browser is running). Options you leave out use the server's defaults. Every command takes `--json` to print the raw API response. Run `remotebrowser --help`, or `remotebrowser <command> --help`, for details.

The CDP endpoint needs the login token in the `Authorization: Bearer` header. `remotebrowser token` prints it. For example, with Playwright for Python:

```python
token = subprocess.run(["remotebrowser", "token"], capture_output=True, text=True, check=True).stdout.strip()
browser = p.chromium.connect_over_cdp(cdp_url, headers={"Authorization": f"Bearer {token}"})
```

### Exit codes

The exit code is 0 on success, 1 when the API call fails, and 2 for a usage error. An API failure prints the status code and the server's message, such as `remotebrowser: 409 Only a suspended browser can be resumed.`

When `delete`, `suspend`, or `resume` gets several ids, it continues after a failure and exits with 1 at the end.

### Retries and timeouts

Connection errors and 408, 429, and 5xx responses are retried up to 2 times, with exponential backoff, and the `Retry-After` header is respected. 409 is not retried, because it means the browser is in the wrong state. Each attempt times out after 60 seconds without a response.
