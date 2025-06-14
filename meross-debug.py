#!/usr/bin/env python3
import os
import sys
import time
import uuid
import hashlib
import requests
import json

BASE_URL = "https://iotx-eu.meross.com/v1"

def md5_str(s: str) -> str:
    return hashlib.md5(s.encode("utf-8")).hexdigest()

class MerossClient:
    def __init__(self, email: str, password: str):
        self.email = email
        self.password = password
        self.token = None
        self.user_id = None
        self.s = requests.Session()

    def login(self):
        timestamp = int(time.time())
        nonce = uuid.uuid4().hex[:8]
        pwd_md5 = md5_str(self.password)
        # El sign suele ser MD5(email + pwd_md5 + timestamp + nonce)
        sign = md5_str(f"{self.email}{pwd_md5}{timestamp}{nonce}")
        body = {
            "email": self.email,
            "password": pwd_md5,
            "timestamp": timestamp,
            "sign": sign,
            "nonce": nonce
        }
        print("→ LOGIN REQ:", json.dumps(body, indent=2))
        resp = self.s.post(f"{BASE_URL}/Auth/signIn", json=body)
        print("← LOGIN RESP:", resp.status_code, resp.text)
        j = resp.json()
        if j.get("data") and j["data"].get("token") and j["data"].get("userId"):
            self.token = j["data"]["token"]
            self.user_id = j["data"]["userId"]
        else:
            raise RuntimeError("Login failed: " + resp.text)

    def list_devices(self):
        ts = int(time.time())
        hdr = {
            "Authorization": self.token,
            "Content-Type": "application/json"
        }
        body = {"timestamp": ts, "userId": self.user_id}
        print("→ DEVLIST REQ:", json.dumps(body, indent=2))
        r = self.s.post(f"{BASE_URL}/Device/devList", json=body, headers=hdr)
        print("← DEVLIST RESP:", r.status_code, r.text)
        return r.json()

    def control(self, device_id: str, channel: int, on: bool):
        ts = int(time.time())
        hdr = {
            "Authorization": self.token,
            "Content-Type": "application/json"
        }
        # namespace y método para control de encendido/apagado
        body = {
            "header": {
                "messageId": str(uuid.uuid4()),
                "namespace": "Appliance.Control.ToggleX",
                "method": "SET",
                "payloadVersion": 1,
                "timestamp": ts,
                "from": "",
                "sign": ""  # opcional según API
            },
            "payload": {
                "deviceId": device_id,
                "channel": channel,
                "onoff": 1 if on else 0
            }
        }
        print("→ CONTROL REQ:", json.dumps(body, indent=2))
        r = self.s.post(f"{BASE_URL}/Appliance.Control.ToggleX", json=body, headers=hdr)
        print("← CONTROL RESP:", r.status_code, r.text)
        return r.json()

def main():
    email = os.getenv("MEROSS_EMAIL")
    password = os.getenv("MEROSS_PASSWORD")
    if not email or not password:
        print("❌ Define MEROSS_EMAIL y MEROSS_PASSWORD en el entorno")
        sys.exit(1)

    cli = MerossClient(email, password)
    cli.login()

    devs = cli.list_devices()
    # Si pasas args, usa esos, sino coge el primer dispositivo en la lista
    if len(sys.argv) >= 3 and sys.argv[1] in ("on", "off"):
        action = sys.argv[1] == "on"
        dev_id = sys.argv[2]
    else:
        # ejemplo por defecto
        dev = devs.get("data", {}).get("list", [])[0]
        dev_id = dev["uuid"]
        action = False
        print(f"ℹ️ Usando primer dispositivo {dev['name']} ({dev_id}), action=off")

    cli.control(device_id=dev_id, channel=0, on=action)

if __name__ == "__main__":
    main()
