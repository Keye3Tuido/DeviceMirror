// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Keye3Tuido
package com.keye3tuido.devicemirror.probe;
import android.app.Activity;
import android.os.Bundle;
import android.view.KeyEvent;
import android.widget.Button;
import android.content.res.Configuration;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;

public class AndroidControlsProbe extends Activity {
    private void record(String value) {
        try (FileOutputStream out = openFileOutput("events.txt", MODE_APPEND)) {
            out.write((value + "\n").getBytes(StandardCharsets.UTF_8));
        } catch (Exception failure) { throw new RuntimeException(failure); }
    }
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        Button button = new Button(this);
        button.setText("Long press probe");
        button.setOnLongClickListener(view -> { record("LONG_TOUCH"); return true; });
        button.setOnClickListener(view -> record("SHORT_TOUCH"));
        setContentView(button);
        record("ORIENTATION " + getResources().getConfiguration().orientation);
    }
    @Override public void onConfigurationChanged(Configuration config) {
        super.onConfigurationChanged(config); record("ORIENTATION " + config.orientation);
    }
    @Override public boolean dispatchKeyEvent(KeyEvent event) {
        if (event.getKeyCode() != KeyEvent.KEYCODE_VOLUME_UP) return super.dispatchKeyEvent(event);
        record("KEY " + event.getAction() + " " + event.getRepeatCount() + " " + event.getFlags()
            + " " + event.getDownTime() + " " + event.getEventTime());
        return true;
    }
}
