"""生成自签证书，给服务开 https 用。

证书是自己在本机生成的（不是花钱买的），手机那边 App 会认。
用法：
    python make_cert.py            # 生成 server/certs/cert.pem + key.pem
    python make_cert.py --force    # 重新生成

证书里的地址（SAN）包括本机所有局域网 IP、127.0.0.1 和 localhost，
所以手机用 http://192.168.x.x:8000 或 https://192.168.x.x:8000 都能连。
"""
import datetime
import ipaddress
import os
import socket
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CERT_DIR = os.path.join(HERE, "certs")
CERT_FILE = os.path.join(CERT_DIR, "cert.pem")
KEY_FILE = os.path.join(CERT_DIR, "key.pem")


def local_ips():
    """这台电脑现在用的 IP（去掉回环地址）"""
    out = []
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("10.255.255.255", 1))
        out.append(s.getsockname()[0])
        s.close()
    except Exception:
        pass
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            ip = info[4][0]
            if not ip.startswith("127.") and ip not in out:
                out.append(ip)
    except Exception:
        pass
    return out


def cert_covers_ip():
    """现有证书里有没有本机现在的 IP（换了网络、IP 变了就得重新生成）"""
    ip = ""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("10.255.255.255", 1))
        ip = s.getsockname()[0]
        s.close()
    except Exception:
        pass
    if not ip:
        return True, ""
    try:
        from cryptography import x509
        with open(CERT_FILE, "rb") as f:
            cert = x509.load_pem_x509_certificate(f.read())
        san = cert.extensions.get_extension_for_class(x509.SubjectAlternativeName).value
        have = set()
        for name in san:
            if isinstance(name, x509.IPAddress):
                have.add(str(name.value))
        if ip not in have:
            return False, ip
        return True, ""
    except Exception:
        return True, ""


def main():
    force = "--force" in sys.argv
    if os.path.exists(CERT_FILE) and os.path.exists(KEY_FILE) and not force:
        ok, missing = cert_covers_ip()
        if ok:
            print("证书已经有了：%s（要重新生成就加 --force）" % CERT_FILE)
            return 0
        print("本机 IP 变成 %s 了（旧证书里没有），重新生成" % missing)
    try:
        from cryptography import x509
        from cryptography.x509.oid import NameOID
        from cryptography.hazmat.primitives import hashes, serialization
        from cryptography.hazmat.primitives.asymmetric import rsa
    except ImportError:
        print("没装 cryptography，先执行：pip install cryptography")
        print("（不装也行，服务会只用 http）")
        return 1

    os.makedirs(CERT_DIR, exist_ok=True)
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "hear-cloud")])

    ips = []
    for ip in local_ips():
        try:
            ips.append(ipaddress.ip_address(ip))
        except ValueError:
            pass
    ips.append(ipaddress.ip_address("127.0.0.1"))

    san = [x509.DNSName("localhost"), x509.DNSName("hear-cloud.local")]
    san += [x509.IPAddress(i) for i in ips]

    now = datetime.datetime.now(datetime.timezone.utc)
    cert = (
        x509.CertificateBuilder()
        .subject_name(name)
        .issuer_name(name)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - datetime.timedelta(days=1))
        .not_valid_after(now + datetime.timedelta(days=3650))
        .add_extension(x509.SubjectAlternativeName(san), critical=False)
        .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
        .sign(key, hashes.SHA256())
    )

    with open(CERT_FILE, "wb") as f:
        f.write(cert.public_bytes(serialization.Encoding.PEM))
    with open(KEY_FILE, "wb") as f:
        f.write(key.private_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PrivateFormat.TraditionalOpenSSL,
            encryption_algorithm=serialization.NoEncryption(),
        ))
    print("证书生成好了：%s" % CERT_FILE)
    print("包含的地址：%s" % ", ".join(str(i) for i in ips))
    return 0


if __name__ == "__main__":
    sys.exit(main())
