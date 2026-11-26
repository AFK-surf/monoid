#!/usr/bin/env python3
"""NDJSON JSON-RPC worker for AirPlay / Apple TV / HomePod control via pyatv.

Communicates exclusively over stdin/stdout (one JSON object per line),
listening on zero network ports.
"""
from __future__ import annotations

import asyncio
import json
import secrets
import sys
import traceback
from typing import Any

try:
    import pyatv
    from pyatv import const as pyatv_const
    from pyatv import exceptions as pyatv_exceptions

    PYATV_IMPORT_ERROR: str | None = None
except Exception as exc:  # pragma: no cover - tested via mock/env
    pyatv = None  # type: ignore[assignment]
    pyatv_const = None  # type: ignore[assignment]
    pyatv_exceptions = None  # type: ignore[assignment]
    PYATV_IMPORT_ERROR = str(exc)


class RpcError(Exception):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


def _require_pyatv() -> None:
    if pyatv is None or pyatv_const is None:
        detail = f" ({PYATV_IMPORT_ERROR})" if PYATV_IMPORT_ERROR else ""
        raise RpcError(
            "pyatv_missing",
            f"pyatv is not installed in this Python environment{detail}. "
            "Install it via POST /devices/airplay/install or `pip install 'pyatv>=0.16,<0.17'`.",
        )


def _protocol_to_name(proto: Any) -> str | None:
    if pyatv_const is None:
        return None
    mapping = {
        pyatv_const.Protocol.AirPlay: "airplay",
        pyatv_const.Protocol.Companion: "companion",
        pyatv_const.Protocol.RAOP: "raop",
    }
    return mapping.get(proto)


def _name_to_protocol(name: str) -> Any:
    _require_pyatv()
    mapping = {
        "airplay": pyatv_const.Protocol.AirPlay,
        "companion": pyatv_const.Protocol.Companion,
        "raop": pyatv_const.Protocol.RAOP,
    }
    proto = mapping.get(name)
    if proto is None:
        raise RpcError("invalid_params", f"unsupported protocol: {name}")
    return proto


def _pairing_req_to_name(req: Any) -> str:
    if pyatv_const is None:
        return "unsupported"
    mapping = {
        pyatv_const.PairingRequirement.Mandatory: "mandatory",
        pyatv_const.PairingRequirement.Optional: "optional",
        pyatv_const.PairingRequirement.NotNeeded: "notNeeded",
        pyatv_const.PairingRequirement.Unsupported: "unsupported",
        pyatv_const.PairingRequirement.Disabled: "disabled",
    }
    return mapping.get(req, "unsupported")


def _enum_name(value: Any) -> str | None:
    if value is None:
        return None
    name = getattr(value, "name", None)
    if isinstance(name, str):
        return name
    return str(value)


def _candidate_dict(atv: Any) -> dict[str, Any]:
    protocols: list[dict[str, str]] = []
    seen: set[str] = set()
    for svc in getattr(atv, "services", []) or []:
        pname = _protocol_to_name(getattr(svc, "protocol", None))
        if pname is None or pname in seen:
            continue
        seen.add(pname)
        protocols.append(
            {
                "protocol": pname,
                "pairing": _pairing_req_to_name(getattr(svc, "pairing", None)),
            }
        )
    dev_info = getattr(atv, "device_info", None)
    model = None
    os_str = None
    if dev_info is not None:
        model = getattr(dev_info, "model_str", None)
        if not model:
            m = getattr(dev_info, "model", None)
            model = _enum_name(m)
        raw_os = getattr(dev_info, "operating_system", None)
        ver = getattr(dev_info, "version", None)
        os_name = _enum_name(raw_os)
        if os_name and ver:
            os_str = f"{os_name} {ver}"
        elif os_name:
            os_str = os_name
        elif ver:
            os_str = str(ver)
    identifier = getattr(atv, "identifier", None) or str(getattr(atv, "address", ""))
    return {
        "identifier": str(identifier),
        "name": str(getattr(atv, "name", "") or identifier),
        "address": str(getattr(atv, "address", "")),
        "model": str(model) if model else "",
        "os": os_str or "",
        "protocols": protocols,
    }


class AirPlayWorker:
    def __init__(self) -> None:
        self._pairings: dict[str, tuple[Any, str]] = {}

    async def close_all(self) -> None:
        items = list(self._pairings.items())
        self._pairings.clear()
        for _, (pairing, _) in items:
            try:
                await pairing.close()
            except Exception:
                pass

    async def handle(self, method: str, params: dict[str, Any]) -> Any:
        if method == "ping":
            return await self._ping()
        if method == "scan":
            return await self._scan(params)
        if method == "pair_start":
            return await self._pair_start(params)
        if method == "pair_finish":
            return await self._pair_finish(params)
        if method == "pair_cancel":
            return await self._pair_cancel(params)
        if method == "control":
            return await self._control(params)
        raise RpcError("unknown_method", f"unknown method: {method}")

    async def _ping(self) -> dict[str, Any]:
        _require_pyatv()
        version = getattr(pyatv_const, "__version__", None) or getattr(pyatv, "__version__", "unknown")
        return {
            "ok": True,
            "pyatvVersion": str(version),
            "pythonVersion": f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}",
        }

    async def _scan(self, params: dict[str, Any]) -> list[dict[str, Any]]:
        _require_pyatv()
        loop = asyncio.get_running_loop()
        timeout_ms = params.get("timeoutMs", 4000)
        try:
            timeout = max(0.5, min(30.0, float(timeout_ms) / 1000.0))
        except (TypeError, ValueError):
            timeout = 4.0
        host = params.get("host")
        kwargs: dict[str, Any] = {"timeout": timeout}
        if isinstance(host, str) and host.strip():
            kwargs["hosts"] = [host.strip()]
        found = await pyatv.scan(loop, **kwargs)
        return [_candidate_dict(atv) for atv in found]

    async def _locate(self, identifier: str, address: str | None = None, timeout: float = 5.0) -> Any:
        _require_pyatv()
        loop = asyncio.get_running_loop()
        hosts = [address.strip()] if isinstance(address, str) and address.strip() else None
        if hosts:
            found = await pyatv.scan(loop, timeout=timeout, hosts=hosts)
            for atv in found:
                if self._matches(atv, identifier, address):
                    return atv
            if len(found) == 1:
                return found[0]
        # Try scanning by identifier directly first (fast path in pyatv)
        found = await pyatv.scan(loop, timeout=timeout, identifier=identifier)
        if found:
            return found[0]
        # Fallback: treat identifier as host/IP if it looks like one
        found = await pyatv.scan(loop, timeout=timeout, hosts=[identifier])
        if found:
            return found[0]
        raise RpcError("device_not_found", f"AirPlay device not found on local network: {identifier}")

    @staticmethod
    def _matches(atv: Any, identifier: str, address: str | None) -> bool:
        target = identifier.lower()
        atv_id = str(getattr(atv, "identifier", "") or "").lower()
        if atv_id == target:
            return True
        all_ids = getattr(atv, "all_identifiers", None)
        if all_ids and any(str(x).lower() == target for x in all_ids):
            return True
        atv_addr = str(getattr(atv, "address", "") or "").lower()
        if atv_addr == target:
            return True
        if address and atv_addr == address.strip().lower():
            return True
        return False

    async def _pair_start(self, params: dict[str, Any]) -> dict[str, Any]:
        _require_pyatv()
        identifier = str(params.get("identifier") or "").strip()
        address = params.get("address")
        proto_name = str(params.get("protocol") or "").strip()
        if not identifier or not proto_name:
            raise RpcError("invalid_params", "identifier and protocol are required")
        proto = _name_to_protocol(proto_name)
        config = await self._locate(identifier, address if isinstance(address, str) else None)
        loop = asyncio.get_running_loop()
        try:
            pairing = await pyatv.pair(config, proto, loop)
            await pairing.begin()
        except Exception as exc:
            raise RpcError("pair_failed", f"failed to start {proto_name} pairing: {exc}") from exc
        token = secrets.token_hex(16)
        self._pairings[token] = (pairing, proto_name)
        return {
            "pairToken": token,
            "protocol": proto_name,
            "deviceProvidesPin": bool(getattr(pairing, "device_provides_pin", True)),
        }

    async def _pair_finish(self, params: dict[str, Any]) -> dict[str, Any]:
        _require_pyatv()
        token = str(params.get("pairToken") or "").strip()
        if not token or token not in self._pairings:
            raise RpcError("invalid_pair_token", "pairing session not found or expired")
        pairing, proto_name = self._pairings.pop(token)
        pin = params.get("pin")
        try:
            if pin is not None and str(pin).strip() != "":
                pairing.pin(str(pin).strip())
            await pairing.finish()
            if not getattr(pairing, "has_paired", False):
                raise RpcError("invalid_pin", "pairing did not complete; check the PIN and try again")
            service = getattr(pairing, "service", None)
            creds = getattr(service, "credentials", None) if service is not None else None
            if not creds:
                raise RpcError("pair_failed", "pairing succeeded but produced no credentials")
            return {"credentials": str(creds), "protocol": proto_name}
        except RpcError:
            raise
        except Exception as exc:
            auth_err = getattr(pyatv_exceptions, "AuthenticationError", None)
            if auth_err is not None and isinstance(exc, auth_err):
                raise RpcError("invalid_pin", f"invalid PIN: {exc}") from exc
            msg = str(exc)
            if "pin" in msg.lower() or "auth" in msg.lower() or "code" in msg.lower():
                raise RpcError("invalid_pin", msg) from exc
            raise RpcError("pair_failed", f"pairing failed: {msg}") from exc
        finally:
            try:
                await pairing.close()
            except Exception:
                pass

    async def _pair_cancel(self, params: dict[str, Any]) -> dict[str, Any]:
        token = str(params.get("pairToken") or "").strip()
        entry = self._pairings.pop(token, None)
        if entry is not None:
            pairing, _ = entry
            try:
                await pairing.close()
            except Exception:
                pass
        return {"ok": True}

    async def _control(self, params: dict[str, Any]) -> Any:
        _require_pyatv()
        identifier = str(params.get("identifier") or "").strip()
        address = params.get("address")
        action = str(params.get("action") or "").strip()
        args = params.get("args") if isinstance(params.get("args"), dict) else {}
        creds = params.get("credentials") if isinstance(params.get("credentials"), dict) else {}
        if not identifier or not action:
            raise RpcError("invalid_params", "identifier and action are required")

        config = await self._locate(identifier, address if isinstance(address, str) else None)
        for pname, cred_val in creds.items():
            if not isinstance(cred_val, str) or not cred_val:
                continue
            try:
                proto = _name_to_protocol(pname)
                config.set_credentials(proto, cred_val)
            except Exception:
                pass

        loop = asyncio.get_running_loop()
        try:
            atv = await pyatv.connect(config, loop)
        except Exception as exc:
            auth_err = getattr(pyatv_exceptions, "AuthenticationError", None)
            if auth_err is not None and isinstance(exc, auth_err):
                raise RpcError("auth_failed", f"authentication failed; device may need re-pairing: {exc}") from exc
            raise RpcError("connect_failed", f"failed to connect to {identifier}: {exc}") from exc

        try:
            return await self._dispatch_action(atv, config, action, args)
        except RpcError:
            raise
        except Exception as exc:
            not_supported = getattr(pyatv_exceptions, "NotSupportedError", None)
            if not_supported is not None and isinstance(exc, not_supported):
                raise RpcError("not_supported", str(exc)) from exc
            auth_err = getattr(pyatv_exceptions, "AuthenticationError", None)
            if auth_err is not None and isinstance(exc, auth_err):
                raise RpcError("auth_failed", str(exc)) from exc
            raise RpcError("action_failed", str(exc)) from exc
        finally:
            try:
                res = atv.close()
                if asyncio.iscoroutine(res):
                    await res
            except Exception:
                pass

    async def _dispatch_action(self, atv: Any, config: Any, action: str, args: dict[str, Any]) -> Any:
        if action == "status":
            info = _candidate_dict(config)
            power_state = None
            try:
                power_state = _enum_name(atv.power.power_state)
            except Exception:
                pass
            app = None
            try:
                meta_app = atv.metadata.app
                if meta_app is not None:
                    app = {"name": meta_app.name, "id": meta_app.identifier}
            except Exception:
                pass
            features: list[str] = []
            try:
                all_features = atv.features.all_features()
                avail = getattr(pyatv_const.FeatureState, "Available", None)
                for fname, finfo in all_features.items():
                    if getattr(finfo, "state", None) == avail:
                        features.append(_enum_name(fname) or str(fname))
            except Exception:
                pass
            return {
                "online": True,
                "identifier": info["identifier"],
                "name": info["name"],
                "address": info["address"],
                "model": info["model"],
                "os": info["os"],
                "powerState": power_state,
                "app": app,
                "features": sorted(features),
            }

        if action == "power":
            state = str(args.get("state") or "get").lower()
            if state == "on":
                await atv.power.turn_on()
            elif state == "off":
                await atv.power.turn_off()
            elif state == "toggle":
                cur = _enum_name(atv.power.power_state) or ""
                if cur.lower() == "on":
                    await atv.power.turn_off()
                else:
                    await atv.power.turn_on()
            elif state != "get":
                raise RpcError("invalid_params", f"power state must be on, off, toggle or get (got {state})")
            return {"ok": True, "powerState": _enum_name(atv.power.power_state)}

        if action == "remote":
            key = str(args.get("key") or "").strip().lower()
            press = str(args.get("press") or "single").strip().lower()
            repeat_raw = args.get("repeat", 1)
            try:
                repeat = max(1, min(20, int(repeat_raw)))
            except (TypeError, ValueError):
                repeat = 1
            action_keys = {
                "up", "down", "left", "right", "select", "menu", "home", "top_menu",
                "play_pause", "play", "pause", "stop", "next", "previous",
            }
            simple_keys = {"volume_up", "volume_down", "skip_forward", "skip_backward"}
            if key not in action_keys and key not in simple_keys:
                raise RpcError("invalid_params", f"unsupported remote key: {key}")
            fn = getattr(atv.remote_control, key, None)
            if fn is None:
                raise RpcError("not_supported", f"remote key not supported: {key}")
            press_map = {
                "single": pyatv_const.InputAction.SingleTap,
                "double": pyatv_const.InputAction.DoubleTap,
                "hold": pyatv_const.InputAction.Hold,
            }
            if press not in press_map:
                raise RpcError("invalid_params", f"press must be single, double or hold (got {press})")
            for _ in range(repeat):
                if key in action_keys:
                    await fn(action=press_map[press])
                else:
                    await fn()
            return {"ok": True, "key": key, "press": press, "repeat": repeat}

        if action == "apps":
            items = await atv.apps.app_list()
            return {"apps": [{"name": a.name, "id": a.identifier} for a in items]}

        if action == "launch":
            target = str(args.get("app") or "").strip()
            if not target:
                raise RpcError("invalid_params", "launch requires args.app")
            launch_id = target
            if "://" not in target:
                try:
                    items = await atv.apps.app_list()
                    low = target.lower()
                    matched = next(
                        (a.identifier for a in items if a.identifier.lower() == low or a.name.lower() == low),
                        None,
                    )
                    if matched is not None:
                        launch_id = matched
                except Exception:
                    pass
            await atv.apps.launch_app(launch_id)
            return {"ok": True, "app": launch_id}

        if action == "playing":
            p = await atv.metadata.playing()
            app = None
            try:
                app = atv.metadata.app
            except Exception:
                pass
            vol = None
            try:
                vol = atv.audio.volume
            except Exception:
                pass
            return {
                "title": getattr(p, "title", None),
                "artist": getattr(p, "artist", None),
                "album": getattr(p, "album", None),
                "app": getattr(app, "name", None) if app is not None else None,
                "appId": getattr(app, "identifier", None) if app is not None else None,
                "mediaType": _enum_name(getattr(p, "media_type", None)),
                "deviceState": _enum_name(getattr(p, "device_state", None)),
                "position": getattr(p, "position", None),
                "totalTime": getattr(p, "total_time", None),
                "volume": vol,
            }

        if action == "seek":
            pos = args.get("position")
            if pos is None or isinstance(pos, bool):
                raise RpcError("invalid_params", "seek requires numeric args.position (seconds)")
            try:
                sec = int(pos)
            except (TypeError, ValueError) as exc:
                raise RpcError("invalid_params", "seek position must be a number") from exc
            if sec < 0:
                raise RpcError("invalid_params", "seek position must be >= 0")
            await atv.remote_control.set_position(sec)
            return {"ok": True, "position": sec}

        if action == "volume":
            level = args.get("level")
            if level is None or isinstance(level, bool):
                raise RpcError("invalid_params", "volume requires numeric args.level (0-100)")
            try:
                val = float(level)
            except (TypeError, ValueError) as exc:
                raise RpcError("invalid_params", "volume level must be a number") from exc
            if val < 0 or val > 100:
                raise RpcError("invalid_params", "volume level must be between 0 and 100")
            await atv.audio.set_volume(val)
            return {"ok": True, "level": val}

        if action == "keyboard":
            kb_action = str(args.get("action") or "set").strip().lower()
            text = args.get("text")
            if kb_action == "clear":
                await atv.keyboard.text_clear()
                return {"ok": True, "action": "clear"}
            if not isinstance(text, str):
                raise RpcError("invalid_params", "keyboard requires string args.text")
            if kb_action == "set":
                await atv.keyboard.text_set(text)
            elif kb_action == "append":
                await atv.keyboard.text_append(text)
            else:
                raise RpcError("invalid_params", f"keyboard action must be set, append or clear (got {kb_action})")
            return {"ok": True, "action": kb_action}

        if action == "play_url":
            url = str(args.get("url") or "").strip()
            if not url:
                raise RpcError("invalid_params", "play_url requires args.url")
            pos = args.get("position")
            if pos is not None and not isinstance(pos, bool):
                await atv.stream.play_url(url, position=float(pos))
            else:
                await atv.stream.play_url(url)
            return {"ok": True, "url": url}

        if action == "stream_audio":
            path = str(args.get("path") or "").strip()
            if not path:
                raise RpcError("invalid_params", "stream_audio requires args.path")
            await atv.stream.stream_file(path)
            return {"ok": True}

        raise RpcError("unknown_action", f"unsupported action: {action}")


def _write_line(obj: dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


async def _handle_line(worker: AirPlayWorker, line: str) -> None:
    req_id: Any = None
    try:
        req = json.loads(line)
        if not isinstance(req, dict):
            raise RpcError("invalid_request", "request must be a JSON object")
        req_id = req.get("id")
        method = req.get("method")
        params = req.get("params")
        if not isinstance(method, str) or not method:
            raise RpcError("invalid_request", "method must be a non-empty string")
        if params is None:
            params = {}
        if not isinstance(params, dict):
            raise RpcError("invalid_params", "params must be an object")
        result = await worker.handle(method, params)
        _write_line({"id": req_id, "ok": True, "result": result})
    except asyncio.CancelledError:
        raise
    except RpcError as err:
        _write_line({"id": req_id, "ok": False, "error": {"code": err.code, "message": err.message}})
    except Exception as exc:
        sys.stderr.write(traceback.format_exc())
        sys.stderr.flush()
        _write_line({"id": req_id, "ok": False, "error": {"code": "internal_error", "message": str(exc)}})


async def main() -> None:
    worker = AirPlayWorker()
    loop = asyncio.get_running_loop()
    reader = asyncio.StreamReader()
    protocol = asyncio.StreamReaderProtocol(reader)
    await loop.connect_read_pipe(lambda: protocol, sys.stdin)
    inflight: set[asyncio.Task[Any]] = set()

    try:
        while True:
            raw = await reader.readline()
            if not raw:
                break
            line = raw.decode("utf-8", errors="replace").strip()
            if not line:
                continue
            task = asyncio.create_task(_handle_line(worker, line))
            inflight.add(task)
            task.add_done_callback(inflight.discard)
        if inflight:
            await asyncio.gather(*list(inflight), return_exceptions=True)
    finally:
        for task in list(inflight):
            if not task.done():
                task.cancel()
        if inflight:
            await asyncio.gather(*list(inflight), return_exceptions=True)
        await worker.close_all()


if __name__ == "__main__":
    asyncio.run(main())
