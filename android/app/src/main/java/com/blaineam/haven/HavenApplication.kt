package com.blaineam.haven

import android.app.Application
import com.blaineam.haven.core.Notifications
import com.blaineam.haven.core.SyncWorker

/** App entry. FFI/identity init is lazy via HavenCore.get(); here we wire background sync. */
class HavenApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        Notifications.ensureChannel(this)
        com.blaineam.haven.core.CircleLock.init(this)   // cheap; avoids an uninit access during first compose
        com.blaineam.haven.core.AvatarStore.init(this)  // photo avatars for feed/people/story-tray
        com.blaineam.haven.core.ScheduledStore.init(this)  // load + fire any due scheduled posts
        com.blaineam.haven.core.CircleSettings.init(this)  // per-circle save/optimize/retention overrides
        SyncWorker.schedule(this)
    }
}
