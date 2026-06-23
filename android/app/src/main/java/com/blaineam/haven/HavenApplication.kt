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
        SyncWorker.schedule(this)
    }
}
