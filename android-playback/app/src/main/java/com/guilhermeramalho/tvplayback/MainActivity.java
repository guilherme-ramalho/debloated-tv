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
        if(runtime!=null){String access=runtime.accessEnabled()?"Playback access enabled":"Playback access is not enabled yet";String pairing=runtime.pairingText();if(!status.getText().toString().equals(access))status.setText(access);if(!code.getText().toString().equals(pairing))code.setText(pairing);}
        handler.postDelayed(this,500);
    }};
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);runtime=PlaybackRuntime.request(this);
        ScrollView scroll=new ScrollView(this);scroll.setFillViewport(true);scroll.setBackgroundColor(Color.rgb(11,19,40));
        LinearLayout root=new LinearLayout(this);root.setOrientation(LinearLayout.VERTICAL);root.setPadding(dp(48),dp(24),dp(48),dp(24));
        root.addView(text("TV Playback",30));
        root.addView(text("Shares the current streaming app, title and HDMI device name with your paired iPhone over an encrypted local connection.",17));
        root.addView(text("Android calls the required permission Notification access. This app uses it only for media sessions; it never reads notification contents or saves viewing history.",15));
        status=text("",17);root.addView(status);
        Button access=new Button(this);access.setText("Enable playback access");access.setOnClickListener(v->{
            try{startActivity(new Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS));}
            catch(ActivityNotFoundException e){status.setText("This TV needs playback access enabled during setup.");}
        });addButton(root,access);
        Button pair=new Button(this);pair.setText("Connect iPhone");pair.setOnClickListener(v->runtime.openPairing());addButton(root,pair);
        code=text("",26);root.addView(code);scroll.addView(root);setContentView(scroll);access.requestFocus();
    }
    private int dp(int value){return Math.round(value*getResources().getDisplayMetrics().density);}
    private void addButton(LinearLayout root,Button button){button.setMinHeight(dp(56));button.setPadding(dp(20),dp(12),dp(20),dp(12));LinearLayout.LayoutParams params=new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT,ViewGroup.LayoutParams.WRAP_CONTENT);params.topMargin=dp(6);root.addView(button,params);}
    private TextView text(String value,int size){TextView t=new TextView(this);t.setText(value);t.setTextColor(Color.rgb(234,245,255));t.setTextSize(size);t.setPadding(0,dp(6),0,dp(9));return t;}
    @Override protected void onResume(){super.onResume();runtime.setupVisible(true);handler.post(update);}
    @Override protected void onPause(){handler.removeCallbacks(update);runtime.setupVisible(false);super.onPause();}
}
