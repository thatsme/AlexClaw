# OpenBao's configuration, shared by production (`openbao`) and the test stack
# (`openbao-test`). The service's environment sets its own addresses
# (BAO_API_ADDR, BAO_CLUSTER_ADDR). See docs/architecture/openbao.md.

# Integrated raft storage. /openbao/file exists in the image, owned by the
# openbao user, so a volume (production) or tmpfs (test stack) mounted there
# is writable by it; a root-owned /openbao/data would not be.
storage "raft" {
  path    = "/openbao/file"
  node_id = "openbao"
}

# TLS only. The certificate and key are written by the init service, signed by
# a CA whose key it discards; AlexClaw verifies against that CA's certificate.
listener "tcp" {
  address         = "0.0.0.0:8200"
  tls_cert_file   = "/openbao/tls/server.pem"
  tls_key_file    = "/openbao/tls/server.key"
  tls_min_version = "tls13"
}

# Automatic unseal from a 32-byte key file on the host, mounted read-only and
# outside the data volume. To rotate: put the new key in current_key (with a new
# id) and the old one in previous_key.
seal "static" {
  current_key_id = "1"
  current_key    = "file:///openbao/unseal/key"
}

# Declared here because OpenBao refuses to create audit devices through its API
# (unsafe_allow_api_audit_creation is off). On the data volume, out of
# AlexClaw's reach. Values are HMAC'd.
audit "file" "alexclaw" {
  options {
    file_path = "/openbao/file/audit.log"
  }
}
