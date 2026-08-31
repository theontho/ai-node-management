# Secrets and Account Authentication

## Objective

Allow unattended resident AI agents to use approved external services without:

- embedding personal passwords or application credentials in installer images;
- copying broad, long-lived secrets to every node;
- requiring routine password entry or per-action human approval; or
- giving untrusted project code access to the owner's accounts.

This document records the architecture research current as of 2026-08-30.

## Fundamental constraint

Unattended authority cannot come from nowhere. At least one durable root of
trust must exist somewhere, such as:

- a non-exportable node key;
- an OAuth refresh token;
- a provider application credential;
- a password-manager service-account token;
- an authenticated browser profile; or
- an owner-held recovery credential.

The system can move, reduce, bind, scope, rotate, and monitor that trust. It
cannot eliminate it while retaining autonomous access.

If a process is authorized to perform an action, compromise of that process can
usually cause the same action while the authorization remains valid. Keeping
the underlying password hidden is valuable, but it does not make an authorized
capability harmless.

## Encryption at rest is not runtime isolation

These technologies protect credentials against offline disk theft and
accidental disclosure:

- BitLocker or Linux full-disk encryption;
- Windows DPAPI or CNG-backed storage;
- TPM-encrypted systemd credentials;
- encrypted Vault storage; and
- encrypted password-manager data.

They do not prevent a compromised live process, running as the authorized
identity, from requesting that a credential be decrypted or used. Root or
administrator compromise can usually subvert local secret consumers.

Design the capability itself to have a safe blast radius.

## Recommended architecture

```text
                    Owner recovery and policy administration
                                      |
                                      v
                    Central credential/capability broker
                    - provider credentials and refresh tokens
                    - policy and rate limits
                    - token issuance
                    - transaction execution
                    - audit and revocation
                       /                         \
                      /                           \
       mTLS or signed challenge             Provider APIs
                    /                       GitHub, Google,
                   /                        Microsoft, email,
        Linux or Windows node               LLM, 1Password
        - TPM-backed node key
        - non-admin agent runtime
        - sandboxed project workers
        - short-lived token or typed action request
```

The central broker must remain available while the Mac is closed. Strong
placement options include:

1. A small separately administered always-on system.
2. A narrowly exposed hardened service on a trusted node, isolated from
   project workers.
3. A managed secrets or identity service combined with a small policy/action
   gateway.

Putting the broker on the same machine as an untrusted worker is still useful
for process separation, but it does not protect broker roots from full
administrator compromise of that machine.

The broker should not execute repositories, agent-generated shell commands, or
downloaded code.

## One root and one agent-facing interface

The provider list does not imply that every node needs eight unrelated
authentication environments. The intended abstraction is:

```text
Agent -> one node identity -> one broker API -> one central vault
                                             -> provider adapters
```

The central vault can be the password-manager-like root. It stores the small
set of durable materials that cannot be eliminated:

- provider application private keys;
- OAuth refresh tokens;
- narrowly scoped API keys;
- browser-session recovery material where unavoidable; and
- broker and recovery roots.

Each node enrolls once with the broker. It does not separately store GitHub,
Google, Microsoft, email, LLM, and 1Password credentials. The agent sees one
consistent interface, for example:

```text
request_token(service, resource, permissions, ttl)
invoke_action(service, action, structured_parameters)
```

Provider adapters behind the broker understand how to use the corresponding
vault item. A GitHub adapter mints an installation token, a Google adapter
performs an OAuth exchange, an email adapter sends an allowlisted message, and
an LLM adapter applies project and spend limits. Those are implementation
details behind one boundary, not separate trust roots distributed to every
agent.

This distinction mirrors a human password manager:

- the **vault** stores many kinds of credential;
- one unlock identity grants the human access to the vault;
- the browser or application still knows how to submit each credential to its
  particular provider.

A vault unifies storage and retrieval, but it cannot make every provider use
the same protocol. Passwords, passkeys, OAuth grants, API keys, GitHub App
installation tokens, browser cookies, and SSH certificates represent different
authorization mechanisms and lifecycle rules.

### Simpler direct-vault model

The simplest implementation can give an agent a service-account identity that
reads selected items from one automation vault. This provides one interface
and may be acceptable for dedicated low-risk accounts.

Its security boundary is straightforward: any code running as that agent may
be able to retrieve and exfiltrate every item the service account can read.
Encryption at rest does not change this. Use:

- a dedicated automation vault, never the owner's personal vault;
- one vault or access policy per trust domain;
- narrowly scoped provider accounts;
- no host-admin, recovery, primary-email, or password-manager credentials; and
- complete access logging and rapid service-account revocation.

### Vault-backed broker model

The stronger model keeps the same central vault but lets only the broker read
it. Workers authenticate to the broker and receive either a short-lived token
or the result of an allowed action. This prevents ordinary project code from
enumerating or dumping the vault.

The broker is therefore analogous to a password manager plus controlled
autofill: it selects the correct credential and uses it only for a permitted
destination and operation. The agent does not need to know which underlying
OAuth, key, or password mechanism was used.

Provider setup still occurs once when a new service is enrolled. That setup is
unavoidable because the provider must decide what the automation is allowed to
do. It should not be repeated per node: all enrolled nodes use the same broker
interface and centrally managed policy.

## Selected direct-vault operating model

For the initial two-node system, a direct-vault model is a reasonable choice:

```text
Dedicated automation vault
            |
   restricted vault identity
            |
Trusted resident agent/controller
      /                  \
credential application   sandboxed project workers
and browser sessions     with no vault access
```

The trusted resident agent may retrieve credentials and apply them wherever
needed. That can include:

- setting an API token for one controlled process;
- authenticating a CLI;
- entering a username, password, and TOTP code in a browser;
- renewing an OAuth session;
- installing an SSH key for a defined destination; and
- maintaining a persistent isolated browser profile.

The vault is the unified authentication root. Provider-specific login mechanics
are handled by the agent's credential-application tools and are not separate
trust environments.

The critical boundary is between the trusted controller and everything it
executes. Repository code, dependency hooks, tests, downloaded installers, and
general shell commands must run under an identity that cannot:

- read the vault service-account token;
- invoke the vault CLI or API through the controller's identity;
- inspect the controller's environment or process memory;
- access authenticated browser profiles;
- read temporary credential files; or
- use an inherited SSH agent or credential socket.

Where practical, the controller should apply a credential without placing its
plaintext value in model context. For example, a credential helper can populate
a target process environment, browser field, or configuration pipe directly.
This reduces accidental logging and model-provider exposure. It does not change
the fact that compromise of the trusted controller can use or retrieve every
vault item it is allowed to access.

Use a dedicated automation vault rather than the owner's complete personal
vault. If multiple resident agents or trust domains exist, use separate vault
access policies so compromise of one node does not automatically expose every
account.

The unattended vault credential remains a root of trust. Store it outside the
installer image, protect it at rest with the node's TPM and operating-system
keystore, and release it only to the trusted controller service at boot. Revoke
that vault identity immediately if the node is lost or compromised.

### Authentication limits

Vault access does not guarantee that every provider can always log in without a
human. Providers may require:

- initial OAuth consent;
- CAPTCHA or abuse review;
- device approval;
- password-reset confirmation;
- WebAuthn user presence;
- risk-based MFA; or
- reauthentication after provider-side revocation.

For reliable unattended use, prefer dedicated automation accounts and
authentication methods designed for noninteractive access. Storing both a
password and TOTP seed in the same automation vault can remove routine prompts,
but vault compromise then defeats both factors. Persistent browser sessions
reduce repeated login challenges but are themselves credentials stored on the
node.

The owner may therefore need to intervene for initial enrollment, provider
security events, recovery, and services that require a human-presence factor.
Routine use can remain autonomous.

## Identity boundaries

| Identity | Intended authority |
|---|---|
| Owner/recovery administrator | Enrollment, recovery, root rotation, and exceptional policy expansion |
| Host maintainer | Operating-system patching and service lifecycle, but no provider authority by default |
| Node identity | Authenticate one enrolled physical machine to the broker |
| Resident agent identity | Request capabilities for its assigned workload |
| Project worker identity | Run untrusted code with no standing provider or host-admin credentials |
| Broker identity | Protect provider roots and enforce policy; never execute project code |
| Provider application identity | Access only selected provider resources and operations |

Do not use a single identity for host maintenance, personal accounts, resident
agents, and arbitrary project execution.

## TPM-backed node identity

Each node should eventually enroll with a unique private key generated or held
by TPM 2.0:

- only the public key or certificate is registered with the broker;
- the private key is marked non-exportable where supported;
- the node proves possession by signing a nonce or completing mTLS;
- the broker maps the key to a specific node and allowed workloads; and
- a lost or compromised node can be disabled centrally.

Windows can use TPM-backed CNG keys. Linux can use a mature TPM2/PKCS#11 or
system service rather than exposing key material to the worker.

TPM binding reduces credential copying and offline theft. It does not prevent
malware running in the authorized context from asking the TPM to sign a broker
request. The broker must still restrict actions by node, workload, project,
provider, resource, operation, rate, and time.

Strict measured-boot attestation can be added later. Do not initially bind
availability to fragile firmware, kernel, or PCR expectations without testing
normal update and recovery paths.

## Two broker modes

### Short-lived token broker

Use this when the provider supports narrow, temporary credentials.

Example request:

```text
subject: ai-node-windows/project-installer-tests
credential: github-installation-token
repositories: owner/installer
permissions: contents:read, issues:write
audience: api.github.com
ttl: 10 minutes
```

The worker receives only the temporary token. Prefer:

- a 5-15 minute TTL for consequential access;
- a provider- and resource-specific audience;
- the minimum operation scope;
- sender-constrained tokens when supported;
- renewal only after identity and policy reevaluation; and
- explicit revocation by node, workload, or provider integration.

Short TTL limits exposure duration, not immediate damage. A powerful ten-minute
token is still powerful.

### Transaction or capability broker

Use this for consequential actions or providers with overly broad tokens. The
agent requests an operation, and the broker calls the provider itself.

Example:

```json
{
  "action": "send_build_notification",
  "recipients": ["allowed@example.com"],
  "template": "installer-test-summary-v1",
  "run_id": "run-123",
  "idempotency_key": "run-123-complete"
}
```

The broker validates:

- the authenticated node and workload;
- the action schema;
- resource and recipient allowlists;
- rate, cost, and volume limits;
- allowed attachments and data classification;
- idempotency and replay protection; and
- the current policy version.

The agent never receives the email, Graph, or other provider credential.

A transaction broker is generally safer than returning a broad credential, but
the permitted action remains real. A compromised agent can still misuse
everything the broker preauthorizes.

Never implement a privileged broker endpoint that accepts an arbitrary URL,
provider request body, shell command, or "run this with my credential."

## OAuth and unattended sessions

OAuth avoids distributing a user's password, but it does not eliminate
persistent authority:

- access tokens are usually bearer credentials usable until expiry;
- refresh tokens can obtain new access tokens and are standing authority;
- device authorization is a bootstrap and consent flow, not permanent
  credential-free access; and
- browser cookies and sessions are also credentials.

For personal-account OAuth, the owner may need one initial interactive consent
and MFA event. After that, the broker can retain the refresh token and issue or
use short-lived access tokens without routine approval. Reauthentication may
still be required after provider revocation, policy change, credential expiry,
or suspicious activity. No safe design can guarantee that a third-party
provider will never require the owner again.

Prefer workload identity federation or application credentials for machine
work. Use delegated personal OAuth only when the action truly needs the owner's
identity.

## Service-specific recommendations

### GitHub

Prefer a GitHub App installed only on the required repositories:

- grant minimal repository permissions;
- protect the App private key at the broker;
- mint short-lived installation tokens when needed;
- use installation identity for unattended automation; and
- use user-delegated identity only when personal attribution is required.

Avoid classic personal access tokens. Use fine-grained PATs only when a GitHub
App cannot support the required operation, and keep each token limited to the
smallest resource set.

### Google Cloud

Prefer Workload Identity Federation for on-premises nodes. It exchanges a
trusted external identity for short-lived Google credentials and avoids
downloaded service-account key files.

Create separate workload pools, identities, and resource bindings for
production, testing, and unrelated projects. Restrict mapped identity claims
and validate the intended audience.

### Google Workspace and Gmail

Prefer a dedicated automation account or tightly scoped OAuth client rather
than the owner's primary Google account.

- Request `gmail.send` only when sending is required.
- Separate reading and sending identities.
- Limit mailbox folders, recipients, templates, and attachment types through
  the broker.
- Consider draft creation instead of immediate sending.

Access to a primary email account is close to identity-administration access
because email can receive password-reset and recovery messages. Do not give a
general coding worker broad primary-mailbox authority.

Google Workspace domain-wide delegation is powerful impersonation and applies
to managed Workspace domains, not ordinary consumer accounts. It requires
advance administrator authorization and narrowly constrained scopes.

### Microsoft and Microsoft Graph

Use a separate Entra application or service principal per automation domain:

- prefer a certificate or federated credential over a shared client secret;
- grant the least Graph application permissions;
- restrict resources such as mailboxes where supported;
- keep app-only and user-delegated authority distinct; and
- validate both application identity and token issuer.

The client-credentials flow is designed for unattended daemons. It grants
authority to the application itself and does not issue a refresh token; the
application credential or federation remains the root used to request new
access tokens.

### Email

Use a dedicated automation mailbox rather than a primary personal mailbox.
Expose typed broker actions such as:

- send a fixed status template to an allowlisted recipient;
- create a draft for later review;
- read one dedicated folder or label;
- extract defined fields with redaction; and
- attach only artifacts from an approved path and size range.

Do not silently preauthorize arbitrary recipients, arbitrary attachments, or
unrestricted mailbox search.

### LLM providers

Use separate provider projects or service identities per node, project, or
trust domain. Put API keys behind a proxy or broker when possible and enforce:

- model allowlists;
- spend and request limits;
- per-project attribution;
- request and response size limits;
- data-egress policy;
- prompt and log redaction; and
- independent revocation.

Do not put one owner-level LLM key in every repository environment.

### 1Password

Do not sign an autonomous agent into the owner's personal 1Password account.

For a minimal deployment, use a 1Password Service Account limited to a
dedicated automation vault and the minimum allowed actions. Keep its token at
the broker rather than in worker environments. Service Accounts are
non-personal and can be scoped to selected vaults and environments, but their
tokens are still standing credentials.

1Password Connect can provide a centralized API, but it caches vault data in
its infrastructure. Deploy it only inside the broker boundary and only for a
dedicated automation vault whose compromise impact is acceptable.

Tools that inject a secret into an environment variable or child process make
the secret available to that process. Injection reduces storage and accidental
leakage; it does not protect against hostile code in the same process.

### SSH host maintenance

Initially use unique maintenance keys and accounts. A stronger future design
uses an SSH certificate authority:

- the external maintenance identity requests a short-lived certificate;
- the certificate names the permitted principal and validity period;
- hosts trust the SSH CA rather than every long-lived user key; and
- compromise can be addressed through expiry and revocation.

Do not forward the owner's general SSH agent into project workers.

### Browser-only accounts

Browser-only automation is a controlled exception:

1. Prefer a separate low-privilege provider account.
2. Run it in a dedicated browser VM or OS identity.
3. Keep the browser profile away from project workspaces and code execution.
4. Do not sign the profile into the owner's password manager, primary email,
   cloud drive, or identity-provider account.
5. Restrict reachable domains, downloads, uploads, clipboard, and local files.
6. Log structured actions and redact screenshots where necessary.
7. Reset and reauthenticate after suspected compromise.

A persistent browser profile is a credential container. Passkeys can make a
private key non-exportable, but a compromised authorized browser can still ask
to use the passkey. Session cookies can grant direct account access and may be
replayable depending on provider controls.

## Prompt injection and untrusted code

External content is data, not authorization. This includes:

- repository instructions and dependency scripts;
- issues, pull requests, and comments;
- email and attachments;
- webpages and downloaded files;
- tool output; and
- model-generated text.

Mandatory separation:

- run project code under per-project unprivileged identities;
- mount no host home directory, SSH agent, browser profile, cloud config, or
  broker root into workers;
- expose no host Docker socket;
- default-deny worker egress where practical;
- give workers only typed broker interfaces;
- prevent agents from modifying broker policy, identity enrollment, audit
  configuration, or their own service definitions; and
- never place credentials in prompts, model context, shell history, ordinary
  logs, or bug reports.

## Policy without routine approval

Avoiding per-action approval means defining safe classes of work in advance.

Reasonable candidates for silent preauthorization:

- read selected repositories;
- create branches or pull requests in selected repositories;
- comment on or label selected issues;
- call an LLM under project-specific budget limits;
- read a dedicated automation inbox;
- send fixed status templates to allowlisted recipients; and
- request a short maintenance certificate for a named node under bounded
  policy.

Do not silently preauthorize:

- password or account recovery;
- changing MFA, trusted devices, or identity enrollment;
- IAM, broker-policy, SSH-CA, or audit-policy changes;
- billing, payments, purchases, or financial transfers;
- deleting accounts or large amounts of data;
- arbitrary external recipients or uploads; or
- unrestricted access to the owner's primary email or password manager.

High-risk actions need a separate break-glass or human authorization path. That
does not require approving normal routine work.

## Audit, revocation, and failure policy

Maintain an inventory of:

- node and workload identities;
- provider integrations and their owners;
- allowed resources, actions, scopes, and audiences;
- credential or certificate lifetime;
- rate and spend limits;
- revocation procedures; and
- recovery ownership.

Broker logs should record the node, workload, project, requested action, policy
decision, provider request identifier, and result. Never log passwords, API
keys, access tokens, refresh tokens, or unnecessarily sensitive content.

Provide:

- one-step disablement of any node or workload;
- provider-side token and application revocation;
- routine key and certificate rotation;
- unusual-use alerts;
- append-only or remotely shipped audit events;
- encrypted broker-configuration backups; and
- offline break-glass recovery material held outside agent nodes.

Fail closed for write, send, delete, administrative, and financial operations.
Do not automatically fall back to a broad static secret when the broker is
unavailable.

## Practical staged plan

### Stage 0: classify and separate

1. Inventory every desired account and operation.
2. Classify operations as read-only, bounded write, consequential write, or
   account/identity administration.
3. Create separate host-maintenance, resident-agent, and project-worker OS
   identities.
4. Remove personal passwords, broad PATs, primary browser profiles, forwarded
   SSH agents, and personal password-manager sessions from workers.
5. Define per-project filesystem and network boundaries.

### Stage 1: minimal unattended system

1. Create a dedicated automation vault and restricted service identity.
2. Protect the service identity at rest with the node's hardware and OS
   keystore, and expose it only to the trusted resident controller.
3. Run all repository and downloaded code in worker identities that cannot
   access the vault, controller process, or authenticated browser profiles.
4. Add credentials gradually, preferring dedicated automation accounts and
   provider application identities over primary personal accounts.
5. Enable vault access reporting, one-step node revocation, and
   credential-rotation runbooks before expanding authority.
6. Use persistent isolated browser profiles only for providers that lack useful
   APIs or noninteractive authentication.

### Stage 2: stronger identity and federation

1. Place a broker in front of the same central vault for operations that need
   narrower authorization than raw vault access can provide.
2. Use mTLS from TPM-backed node keys to the broker.
3. Adopt Google Workload Identity Federation and Entra
   certificate/federated credentials where applicable.
4. Add short-lived SSH certificates.
5. Add policy-as-code, alerting, remote append-only audit, and revoke/rebuild
   drills.
6. Move browser exceptions into dedicated VMs.

### Stage 3: expansion

Consider Vault when dynamic credentials, leases, provider backends, and a
central policy engine justify its operational cost. Vault Agent can retrieve
and renew secrets, but a rendered secret remains visible to its workload.

Consider SPIFFE/SPIRE when many containers and services need distinct,
automatically rotated workload identities and mutual TLS. It is credible but
probably unnecessary for the first two nodes.

## Recommended starting position

For these two nodes:

- do not embed account credentials in either installer;
- retain only host bootstrap and recovery credentials in private installation
  artifacts;
- give the trusted resident controller restricted access to a dedicated
  automation vault;
- keep the owner's full personal vault inaccessible;
- run project code with no access to the vault identity, controller process, or
  authenticated browser sessions;
- prefer dedicated provider application identities and automation accounts;
- protect each node's vault bootstrap with hardware-backed storage and maintain
  rapid central revocation;
- use a broker later for especially consequential or easily constrained
  actions;
- keep browser sessions isolated and exceptional; and
- reserve manual action for initial consent, recovery, and privilege expansion,
  not routine jobs.

This provides the password-manager-like experience: one vault identity per
trusted controller and centrally managed account items. It does not pretend the
controller lacks credentials. The security benefit comes from keeping that
vault authority away from the untrusted workers the controller launches.

## Official references

- [Microsoft: Trusted Platform Module technology overview](https://learn.microsoft.com/en-us/windows/security/hardware-security/tpm/trusted-platform-module-overview)
- [IETF RFC 9700: OAuth 2.0 Security Best Current Practice](https://www.rfc-editor.org/rfc/rfc9700.html)
- [IETF RFC 8693: OAuth 2.0 Token Exchange](https://www.rfc-editor.org/rfc/rfc8693.html)
- [GitHub: About authentication with a GitHub App](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/about-authentication-with-a-github-app)
- [GitHub: Managing personal access tokens](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens)
- [Google: Using OAuth 2.0 to access Google APIs](https://developers.google.com/identity/protocols/oauth2)
- [Google Cloud: Workload Identity Federation](https://cloud.google.com/iam/docs/workload-identity-federation)
- [Google Cloud: Service-account key best practices](https://cloud.google.com/iam/docs/best-practices-for-managing-service-account-keys)
- [Google Workspace: Gmail authorization scopes](https://developers.google.com/workspace/gmail/api/auth/scopes)
- [Microsoft Entra: OAuth 2.0 client credentials flow](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-client-creds-grant-flow)
- [Microsoft Graph: Get access without a user](https://learn.microsoft.com/en-us/graph/auth-v2-service)
- [1Password: Service Accounts](https://www.1password.dev/service-accounts)
- [1Password: Connect](https://www.1password.dev/connect)
- [HashiCorp Vault: AppRole authentication](https://developer.hashicorp.com/vault/docs/auth/approle)
- [HashiCorp Vault: JWT/OIDC authentication](https://developer.hashicorp.com/vault/docs/auth/jwt)
- [SPIFFE: About SPIRE](https://spiffe.io/docs/latest/spire-about/)
- [systemd: systemd-creds](https://www.freedesktop.org/software/systemd/man/latest/systemd-creds.html)
- [OpenSSH: Certificates and key revocation](https://man.openbsd.org/ssh-keygen#CERTIFICATES)
