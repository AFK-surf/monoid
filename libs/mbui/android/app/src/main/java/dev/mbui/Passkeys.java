package dev.mbui;

import android.annotation.TargetApi;
import android.app.Activity;
import android.content.ContentResolver;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ResolveInfo;
import android.credentials.CredentialManager;
import android.credentials.CredentialOption;
import android.credentials.GetCredentialException;
import android.credentials.GetCredentialRequest;
import android.credentials.GetCredentialResponse;
import android.os.Build;
import android.os.Bundle;
import android.os.CancellationSignal;
import android.os.OutcomeReceiver;
import android.provider.Settings;
import android.util.Base64;

import org.json.JSONArray;
import org.json.JSONObject;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.List;
import java.util.Locale;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * This device's passkeys on Android 14+ (API 34+, {@code android.credentials.CredentialManager};
 * {@code src/hostapi/passkeys.mbt}), asked to sign a relying party's challenge and {@code clientDataHash} on behalf of
 * a browser page's {@code origin} ({@code CREDENTIAL_MANAGER_SET_ORIGIN}).
 *
 * <p>Google Password Manager ({@code com.google.android.gms}) enforces its own static browser allowlist for
 * {@code setOrigin}, whereas third-party {@code CredentialProviderService} providers enabled in system settings
 * (1Password, Bitwarden, Proton Pass, KeePassDX, etc.) can sign when allowed by the user. {@link #able()} therefore
 * reports {@code 1} only when a non-GMS credential provider is enabled (or {@code MBUI_ANDROID_PASSKEYS=1}), leaving
 * GMS-only devices on the station's non-intercepted fallback so sign-in pages never stall.
 */
final class Passkeys {
    private static final char SEP_CH = (char) 0x1f;
    private static final String SEP = String.valueOf(SEP_CH);

    private static final class Ask {
        final CancellationSignal cancel = new CancellationSignal();
        volatile String done;
    }

    private static final ConcurrentHashMap<Integer, Ask> asks = new ConcurrentHashMap<>();
    private static final AtomicInteger nextId = new AtomicInteger(1);

    private Passkeys() {}

    private static Context context() {
        Activity a = Host.activity;
        if (a != null) return a;
        MBView v = Host.view;
        return v != null ? v.getContext() : null;
    }

    /** 1 on Android 14+ when CredentialManager and a third-party passkey provider are enabled; else 0. */
    static int able() {
        if (Build.VERSION.SDK_INT < 34) return 0;
        Context ctx = context();
        return ctx != null && Api34.able(ctx) ? 1 : 0;
    }

    /**
     * Starts an assertion request ({@code rpId<US>clientData<US>userVerification<US>hexIds<US>}): positive ask id, or
     * 0 where none could be started.
     */
    static int get(String ask) {
        if (Build.VERSION.SDK_INT < 34 || ask == null) return 0;
        Context ctx = context();
        if (ctx == null || !Api34.able(ctx)) return 0;
        String[] parts = splitSep(ask);
        if (parts == null) return 0;
        String rpId = parts[0];
        String clientData = parts[1];
        String uvIn = parts[2];
        String hexIds = parts[3];
        if (rpId.isEmpty() || clientData.isEmpty()) return 0;
        try {
            JSONObject clientJson = new JSONObject(clientData);
            String challenge = clientJson.optString("challenge", "");
            String origin = clientJson.optString("origin", "");
            if (challenge.isEmpty() || origin.isEmpty()) return 0;
            byte[] clientHash = MessageDigest.getInstance("SHA-256")
                    .digest(clientData.getBytes(StandardCharsets.UTF_8));
            String uv = "required".equals(uvIn) || "discouraged".equals(uvIn) ? uvIn : "preferred";
            JSONObject reqJson = new JSONObject();
            reqJson.put("challenge", challenge);
            reqJson.put("rpId", rpId);
            reqJson.put("userVerification", uv);
            reqJson.put("timeout", 120000);
            JSONArray allow = parseAllow(hexIds);
            if (allow.length() > 0) reqJson.put("allowCredentials", allow);

            int id = nextId.getAndIncrement();
            Ask entry = new Ask();
            asks.put(id, entry);
            final String reqStr = reqJson.toString();
            Host.main.post(() -> Api34.start(id, entry, origin, reqStr, clientData, clientHash));
            return id;
        } catch (Throwable t) {
            Host.log("passkeys: bad ask: " + t);
            return 0;
        }
    }

    /** How ask {@code id} ended once finished; {@code ""} while still waiting. */
    static String out(int id) {
        Ask a = asks.get(id);
        String d = a != null ? a.done : null;
        return d != null ? d : "";
    }

    /** Cancels and forgets ask {@code id}. */
    static void end(int id) {
        Ask a = asks.remove(id);
        if (a != null && a.done == null) {
            try {
                a.cancel.cancel();
            } catch (Throwable ignored) {
            }
        }
    }

    static void finish(int id, String done) {
        Ask a = asks.get(id);
        if (a != null && a.done == null) {
            a.done = done;
            Host.requestFrame();
        }
    }

    static String failed(int code, String why) {
        String clean = why == null ? "" : why.replace(SEP_CH, ' ').replace('\n', ' ').trim();
        return code + SEP + SEP + SEP + SEP + SEP + clean + SEP + SEP;
    }

    private static String[] splitSep(String s) {
        String[] out = new String[4];
        int from = 0;
        for (int k = 0; k < 4; k++) {
            int at = s.indexOf(SEP_CH, from);
            if (at < 0) return null;
            out[k] = s.substring(from, at);
            from = at + 1;
        }
        return out;
    }

    private static JSONArray parseAllow(String hexIds) throws Exception {
        JSONArray arr = new JSONArray();
        if (hexIds == null || hexIds.isEmpty()) return arr;
        for (String h : hexIds.split(",")) {
            byte[] raw = bytesOfHex(h);
            if (raw != null && raw.length > 0) {
                JSONObject d = new JSONObject();
                d.put("type", "public-key");
                d.put("id", Base64.encodeToString(raw, Base64.URL_SAFE | Base64.NO_PADDING | Base64.NO_WRAP));
                arr.put(d);
            }
        }
        return arr;
    }

    private static byte[] bytesOfHex(String h) {
        if (h == null || h.isEmpty() || (h.length() & 1) != 0) return null;
        byte[] out = new byte[h.length() / 2];
        for (int i = 0; i < out.length; i++) {
            int hi = Character.digit(h.charAt(2 * i), 16);
            int lo = Character.digit(h.charAt(2 * i + 1), 16);
            if (hi < 0 || lo < 0) return null;
            out[i] = (byte) ((hi << 4) | lo);
        }
        return out;
    }

    static byte[] bytesOfB64Url(String s) {
        if (s == null || s.isEmpty()) return new byte[0];
        String norm = s.replace('-', '+').replace('_', '/');
        try {
            return Base64.decode(norm, Base64.DEFAULT);
        } catch (IllegalArgumentException e) {
            return new byte[0];
        }
    }

    static String hexOf(byte[] b) {
        if (b == null || b.length == 0) return "";
        char[] d = "0123456789abcdef".toCharArray();
        char[] out = new char[b.length * 2];
        for (int i = 0; i < b.length; i++) {
            int v = b[i] & 0xff;
            out[2 * i] = d[v >>> 4];
            out[2 * i + 1] = d[v & 0x0f];
        }
        return new String(out);
    }

    @TargetApi(34)
    private static final class Api34 {
        private static final String TYPE_PUBLIC_KEY = "androidx.credentials.TYPE_PUBLIC_KEY_CREDENTIAL";
        private static final String KEY_SUBTYPE = "androidx.credentials.BUNDLE_KEY_SUBTYPE";
        private static final String SUBTYPE_GET_PK =
                "androidx.credentials.BUNDLE_VALUE_SUBTYPE_GET_PUBLIC_KEY_CREDENTIAL_OPTION";
        private static final String KEY_REQUEST_JSON = "androidx.credentials.BUNDLE_KEY_REQUEST_JSON";
        private static final String KEY_CLIENT_DATA_HASH = "androidx.credentials.BUNDLE_KEY_CLIENT_DATA_HASH";
        private static final String KEY_PREFER_IMMEDIATE =
                "androidx.credentials.BUNDLE_KEY_PREFER_IMMEDIATELY_AVAILABLE_CREDENTIALS";
        private static final String KEY_AUTH_RESPONSE_JSON =
                "androidx.credentials.BUNDLE_KEY_AUTHENTICATION_RESPONSE_JSON";
        private static final String PROVIDER_ACTION = "android.service.credentials.CredentialProviderService";

        static boolean able(Context ctx) {
            CredentialManager cm = ctx.getSystemService(CredentialManager.class);
            if (cm == null) return false;
            if ("1".equals(android.system.Os.getenv("MBUI_ANDROID_PASSKEYS"))) return true;
            ContentResolver cr = ctx.getContentResolver();
            boolean readSettings = false;
            try {
                String primary = Settings.Secure.getString(cr, "credential_service_primary");
                String secondary = Settings.Secure.getString(cr, "credential_service");
                readSettings = true;
                return hasThirdPartyProvider(primary) || hasThirdPartyProvider(secondary);
            } catch (Throwable ignored) {
                // Restricted Settings.Secure on custom ROMs: fall back to checking installed third-party providers.
            }
            if (!readSettings) {
                try {
                    List<ResolveInfo> services = ctx.getPackageManager()
                            .queryIntentServices(new Intent(PROVIDER_ACTION), 0);
                    if (services != null) {
                        for (ResolveInfo ri : services) {
                            String pkg = ri.serviceInfo != null ? ri.serviceInfo.packageName : null;
                            if (isThirdPartyPackage(pkg)) return true;
                        }
                    }
                } catch (Throwable ignored) {
                }
            }
            return false;
        }

        private static boolean hasThirdPartyProvider(String list) {
            if (list == null || list.isEmpty()) return false;
            for (String entry : list.split("[:;]")) {
                String trimmed = entry.trim();
                if (trimmed.isEmpty()) continue;
                int slash = trimmed.indexOf('/');
                String pkg = slash > 0 ? trimmed.substring(0, slash) : trimmed;
                if (isThirdPartyPackage(pkg)) return true;
            }
            return false;
        }

        private static boolean isThirdPartyPackage(String pkg) {
            return pkg != null && !pkg.isEmpty()
                    && !"com.google.android.gms".equals(pkg)
                    && !"android".equals(pkg);
        }

        static void start(int id, Ask entry, String origin, String reqJson, String askedClientData, byte[] clientHash) {
            if (!asks.containsKey(id) || entry.done != null) return;
            Activity a = Host.activity;
            if (a == null) {
                finish(id, failed(1, "no activity"));
                return;
            }
            CredentialManager cm = a.getSystemService(CredentialManager.class);
            if (cm == null) {
                finish(id, failed(1, "no CredentialManager"));
                return;
            }
            try {
                Bundle optData = new Bundle();
                optData.putString(KEY_SUBTYPE, SUBTYPE_GET_PK);
                optData.putString(KEY_REQUEST_JSON, reqJson);
                optData.putByteArray(KEY_CLIENT_DATA_HASH, clientHash);

                Bundle candData = new Bundle();
                candData.putString(KEY_SUBTYPE, SUBTYPE_GET_PK);
                candData.putString(KEY_REQUEST_JSON, reqJson);
                candData.putByteArray(KEY_CLIENT_DATA_HASH, clientHash);

                CredentialOption option = new CredentialOption.Builder(TYPE_PUBLIC_KEY, optData, candData).build();
                Bundle topData = new Bundle();
                topData.putBoolean(KEY_PREFER_IMMEDIATE, false);
                GetCredentialRequest request = new GetCredentialRequest.Builder(topData)
                        .addCredentialOption(option)
                        .setOrigin(origin)
                        .build();

                cm.getCredential(a, request, entry.cancel, a.getMainExecutor(),
                        new OutcomeReceiver<GetCredentialResponse, GetCredentialException>() {
                            @Override
                            public void onResult(GetCredentialResponse response) {
                                handleResult(id, response, askedClientData);
                            }

                            @Override
                            public void onError(GetCredentialException e) {
                                handleError(id, e);
                            }
                        });
            } catch (Throwable t) {
                Host.log("passkeys: getCredential threw: " + t);
                finish(id, failed(1, t.getMessage()));
            }
        }

        private static void handleResult(int id, GetCredentialResponse response, String askedClientData) {
            try {
                Bundle data = response.getCredential().getData();
                String authJson = data != null ? data.getString(KEY_AUTH_RESPONSE_JSON) : null;
                if (authJson == null || authJson.isEmpty()) {
                    finish(id, failed(-1, "empty credential response"));
                    return;
                }
                JSONObject root = new JSONObject(authJson);
                String rawId = root.optString("rawId", root.optString("id", ""));
                JSONObject resp = root.getJSONObject("response");
                String authData = resp.getString("authenticatorData");
                String sig = resp.getString("signature");
                String user = resp.isNull("userHandle") ? "" : resp.optString("userHandle", "");
                String clientB64 = resp.optString("clientDataJSON", "");

                String credHex = hexOf(bytesOfB64Url(rawId));
                String authHex = hexOf(bytesOfB64Url(authData));
                String sigHex = hexOf(bytesOfB64Url(sig));
                String userHex = hexOf(bytesOfB64Url(user));
                if (credHex.isEmpty() || authHex.isEmpty() || sigHex.isEmpty()) {
                    finish(id, failed(-1, "incomplete assertion"));
                    return;
                }
                // Providers signing BUNDLE_KEY_CLIENT_DATA_HASH often return a placeholder in clientDataJSON;
                // only forward clientData when the provider built a distinct real webauthn.get JSON payload.
                String clientHex = "";
                byte[] clientBytes = bytesOfB64Url(clientB64);
                if (clientBytes.length > 0) {
                    String clientStr = new String(clientBytes, StandardCharsets.UTF_8);
                    if (!clientStr.equals(askedClientData) && isWebAuthnGetClientData(clientStr)) {
                        clientHex = hexOf(clientBytes);
                    }
                }
                finish(id, "0" + SEP + credHex + SEP + authHex + SEP + sigHex + SEP + userHex
                        + SEP + SEP + clientHex + SEP);
            } catch (Throwable t) {
                Host.log("passkeys: bad assertion JSON: " + t);
                finish(id, failed(-1, t.getMessage()));
            }
        }

        private static boolean isWebAuthnGetClientData(String json) {
            try {
                JSONObject o = new JSONObject(json);
                return "webauthn.get".equals(o.optString("type")) && !o.optString("challenge").isEmpty();
            } catch (Throwable t) {
                return false;
            }
        }

        private static void handleError(int id, GetCredentialException e) {
            String type = e != null && e.getType() != null ? e.getType() : "";
            String msg = e != null && e.getMessage() != null ? e.getMessage() : type;
            String lower = (type + " " + msg).toLowerCase(Locale.ROOT);
            boolean notAllowed = GetCredentialException.TYPE_USER_CANCELED.equals(type)
                    || GetCredentialException.TYPE_NO_CREDENTIAL.equals(type)
                    || lower.contains("cancel")
                    || lower.contains("privileged")
                    || lower.contains("origin")
                    || lower.contains("allowlist")
                    || lower.contains("not allowed")
                    || lower.contains("permission");
            Host.log("passkeys: error (" + type + "): " + msg);
            finish(id, failed(notAllowed ? 1 : -1, msg));
        }
    }
}
