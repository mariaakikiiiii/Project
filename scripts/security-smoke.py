"""Run API first; python3 scripts/security-smoke.py /path/to/trusted-public-cert.pem.
This checks middleware only and does not establish database readiness.
"""
import http.cookiejar
import json
import ssl
import sys
import urllib.error
import urllib.request

context = ssl.create_default_context(cafile=sys.argv[1])
client = urllib.request.build_opener(
    urllib.request.HTTPSHandler(context=context),
    urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))


def call(path, method='GET', body=None, headers=None):
    request = urllib.request.Request(
        'https://localhost:7043/api' + path,
        data=json.dumps(body).encode() if body is not None else None,
        method=method,
        headers={'Content-Type': 'application/json', **(headers or {})})
    try:
        with client.open(request) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as response:
        return response.code, response.read()


status, body = call('/csrf')
assert status == 200
assert json.loads(body)['token']
assert call('/auth/me')[0] == 401
assert call('/games/1/join', 'POST', {})[0] == 401
status, body = call('/auth/login', 'POST', {'email': 'bad', 'password': 'x'})
assert status == 400 and 'CSRF' in json.loads(body)['error']
status, body = call('/auth/login', 'POST', {'email': 'bad', 'password': 'x'},
                    {'X-CSRF-TOKEN': json.loads(call('/csrf')[1])['token']})
assert status == 400 and json.loads(body)['error'] == 'Invalid credentials.'
print('PASS: TLS verification, CSRF issuance, unauthenticated access denial, missing-token rejection, login input validation.')

# Platform upgrade: protected routes stay inaccessible to anonymous callers.
for path, method in [("/me/profile", "GET"), ("/me/notifications", "GET"),
                     ("/games/1", "PUT"), ("/games/1/cancel", "POST"),
                     ("/games/1/sponsored-place", "POST"),
                     ("/me/notifications/1/read", "POST")]:
    assert call(path, method, {} if method != "GET" else None)[0] == 401, path
status, body = call("/config")
assert status == 200
configuration = json.loads(body)
assert configuration["onlinePaymentsAvailable"] is False
assert configuration["payoutAvailable"] is False
assert "apiKey" not in configuration and "connectionString" not in configuration
status, body = call("/auth/reset-password", "POST", {"token": "invalid", "password": "short"},
                    {"X-CSRF-TOKEN": json.loads(call("/csrf")[1])["token"]})
assert status == 400
print("PASS: platform route authorization, public configuration boundaries and reset input validation.")

assert call("/games?category=unknown")[0] == 400
assert call("/games?sportId=1&subtypeId=2")[0] == 400
methods = {item["code"]: item["available"] for item in configuration["paymentMethods"]}
assert methods == {"Cash": True, "Whish": False}
print("PASS: category/subtype input validation and cash/Whish capability boundaries.")
