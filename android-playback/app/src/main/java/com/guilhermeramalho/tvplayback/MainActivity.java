package com.guilhermeramalho.tvplayback;
import android.app.*;
import android.content.*;
import android.graphics.Color;
import android.os.*;
import android.provider.Settings;
import android.view.*;
import android.widget.*;
public final class MainActivity extends Activity {
    private final Handler handler=new Handler(Looper.getMainLooper());
    private TextView status,code;
    private PlaybackRuntime runtime;
    private final Runnable update=new Runnable(){ public void run(){
        if(runtime!=null){status.setText(runtime.accessEnabled()?"Playback access enabled":"Playback access is not enabled yet");code.setText(runtime.pairingText());}
        handler.postDelayed(this,500);
    }};
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);runtime=PlaybackRuntime.get(this);
        LinearLayout root=new LinearLayout(this);root.setOrientation(LinearLayout.VERTICAL);root.setPadding(64,35,64,25);root.setBackgroundColor(Color.rgb(11,19,40));
        root.addView(text("TV Playback",30));
        root.addView(text("Shares the current streaming app, title and HDMI device name with your paired iPhone over an encrypted local connection.",17));
        root.addView(text("Android calls the required permission Notification access. This app uses it only for media sessions; it never reads notification contents or saves viewing history.",15));
        status=text("",17);root.addView(status);
        Button access=new Button(this);access.setText("Enable playback access");access.setOnClickListener(v->{
            try{startActivity(new Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS));}
            catch(ActivityNotFoundException e){status.setText("This TV needs playback access enabled during setup.");}
        });root.addView(access,new LinearLayout.LayoutParams(430,56));
        Button pair=new Button(this);pair.setText("Connect iPhone");pair.setOnClickListener(v->runtime.openPairing());root.addView(pair,new LinearLayout.LayoutParams(430,56));
        code=text("",26);root.addView(code);setContentView(root);access.requestFocus();
    }
    private TextView text(String value,int size){TextView t=new TextView(this);t.setText(value);t.setTextColor(Color.rgb(234,245,255));t.setTextSize(size);t.setPadding(0,6,0,9);return t;}
    @Override protected void onResume(){super.onResume();handler.post(update);}
    @Override protected void onPause(){handler.removeCallbacks(update);super.onPause();}
}
