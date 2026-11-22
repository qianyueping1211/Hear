"""Prepare the certificate used by the local HTTPS service.

    python make_cert.py
    python make_cert.py --force  # replace the server certificate, keeping the signing root
"""
import sys

from hear_cloud import TLS_CERT, ensure_cert, pair_info


def main():
    if not ensure_cert(force="--force" in sys.argv, report=print):
        return 1
    print("HTTPS 服务证书：%s" % TLS_CERT)
    fingerprint = pair_info().get("root_fingerprint")
    if fingerprint:
        print("证书指纹（配对时核对这一串）：%s" % fingerprint)
    return 0


if __name__ == "__main__":
    sys.exit(main())
