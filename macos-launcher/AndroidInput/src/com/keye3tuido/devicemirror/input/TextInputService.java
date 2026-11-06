/* SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Keye3Tuido
 */
package com.keye3tuido.devicemirror.input;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.inputmethodservice.InputMethodService;
import android.os.Build;
import android.util.Base64;
import android.view.inputmethod.InputConnection;
import java.nio.charset.StandardCharsets;

/** Commits text to the focused editor. Only adb shell/system may send commands. */
public final class TextInputService extends InputMethodService {
    private static final String PREFIX = "com.keye3tuido.devicemirror.input.";
    private final BroadcastReceiver receiver = new BroadcastReceiver() {
        @Override public void onReceive(Context context, Intent intent) {
            InputConnection connection = getCurrentInputConnection();
            if (PREFIX.concat("PING").equals(intent.getAction())) {
                setResultCode(connection == null ? 2 : 1);
                return;
            }
            if (connection == null) { setResultCode(2); return; }
            try {
                String encoded = intent.getStringExtra("text");
                if (encoded == null || encoded.length() > 87384) { setResultCode(3); return; }
                byte[] bytes = Base64.decode(encoded, Base64.NO_WRAP);
                if (bytes.length > 65536) { setResultCode(3); return; }
                String text = new String(bytes, StandardCharsets.UTF_8);
                setResultCode(connection.commitText(text, 1) ? 1 : 3);
            } catch (IllegalArgumentException failure) { setResultCode(3); }
        }
    };

    @Override public void onCreate() {
        super.onCreate();
        IntentFilter filter = new IntentFilter(PREFIX + "PING");
        filter.addAction(PREFIX + "COMMIT");
        // DUMP is a system/shell permission; ordinary installed apps cannot
        // read or submit input through this exported receiver.
        if (Build.VERSION.SDK_INT >= 33) {
            registerReceiver(receiver, filter, "android.permission.DUMP", null, Context.RECEIVER_EXPORTED);
        } else {
            registerReceiver(receiver, filter, "android.permission.DUMP", null);
        }
    }

    @Override public void onDestroy() {
        unregisterReceiver(receiver);
        super.onDestroy();
    }
}
