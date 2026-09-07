import importlib.util
import tempfile
import unittest
from pathlib import Path

import yaml


MODULE_PATH = Path(__file__).with_name("configure-wifi.py")
SPEC = importlib.util.spec_from_file_location("configure_wifi", MODULE_PATH)
assert SPEC and SPEC.loader
configure_wifi_module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(configure_wifi_module)

INTERFACE_TOKEN = configure_wifi_module.INTERFACE_TOKEN
WifiConfigurationError = configure_wifi_module.WifiConfigurationError
configure_wifi = configure_wifi_module.configure_wifi


class ConfigureWifiTests(unittest.TestCase):
    def test_rewrites_normalized_autoinstall_and_persistent_profile(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            autoinstall = root / "autoinstall.yaml"
            persistent = root / "60-ai-node-wifi.yaml"
            document = {
                "autoinstall": {
                    "network": {
                        "version": 2,
                        "ethernets": {"wired": {"dhcp4": True}},
                        "wifis": {
                            INTERFACE_TOKEN: {
                                "dhcp4": True,
                                "optional": False,
                                "access-points": {
                                    "Validation Network": {
                                        "password": "validation-passphrase"
                                    }
                                },
                            }
                        },
                    }
                }
            }
            autoinstall.write_text(yaml.safe_dump(document, sort_keys=False))

            configure_wifi(
                autoinstall,
                persistent,
                "wlx001122334455",
            )

            rewritten = yaml.safe_load(autoinstall.read_text())
            network = rewritten["autoinstall"]["network"]
            self.assertIn("wired", network["ethernets"])
            self.assertNotIn(INTERFACE_TOKEN, network["wifis"])
            self.assertIn("wlx001122334455", network["wifis"])
            profile = yaml.safe_load(persistent.read_text())
            self.assertEqual(profile["network"]["renderer"], "networkd")
            self.assertEqual(
                list(profile["network"]["wifis"]),
                ["wlx001122334455"],
            )
            self.assertEqual(persistent.stat().st_mode & 0o777, 0o600)

    def test_rejects_missing_interface_token(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            autoinstall = root / "autoinstall.yaml"
            autoinstall.write_text(
                yaml.safe_dump(
                    {
                        "autoinstall": {
                            "network": {
                                "version": 2,
                                "wifis": {"wlan0": {"dhcp4": True}},
                            }
                        }
                    }
                )
            )
            with self.assertRaises(WifiConfigurationError):
                configure_wifi(
                    autoinstall,
                    root / "wifi.yaml",
                    "wlan0",
                )


if __name__ == "__main__":
    unittest.main()
