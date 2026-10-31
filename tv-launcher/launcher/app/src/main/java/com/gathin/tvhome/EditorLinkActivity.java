package com.gathin.tvhome;

import android.app.Activity;
import android.net.Uri;
import android.os.Bundle;
import android.util.Base64;
import android.util.Log;

/**
 * Receives tvhome://phone-edit?k=KEY from the paired iPhone, through the Android TV Remote Service's app-link
 * launch. Only a phone already paired with the TV's remote service can send it, so the key it carries is what
 * proves the phone to {@link EditorServer}: no second pairing code. Shows nothing and finishes at once, so the
 * app on screen stays where it is.
 */
public class EditorLinkActivity extends Activity {
    private static final String TAG = "TvHome.Editor";

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        try {
            byte[] key = key(getIntent() == null ? null : getIntent().getData());
            if (key != null) {
                EditorServer.start(key, new EditorBackend(getApplicationContext()), line -> Log.i(TAG, line));
            } else {
                Log.w(TAG, "ignored an editor link without a valid key");
            }
        } catch (RuntimeException e) {
            Log.w(TAG, "could not start the phone editor: " + e);
        }
        finish();
        overridePendingTransition(0, 0);
    }

    static byte[] key(Uri link) {
        if (link == null || !"tvhome".equals(link.getScheme()) || !"phone-edit".equals(link.getHost())) return null;
        String k = link.getQueryParameter("k");
        if (k == null || k.length() != 43) return null;   // 32 bytes, base64url without padding
        try {
            byte[] key = Base64.decode(k, Base64.URL_SAFE | Base64.NO_PADDING | Base64.NO_WRAP);
            return key.length == EditorCrypto.KEY_BYTES ? key : null;
        } catch (IllegalArgumentException e) {
            return null;
        }
    }
}
