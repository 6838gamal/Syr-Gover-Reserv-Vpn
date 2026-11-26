package gamalsolutions.syria.syrgovervpn

object AppLifecycle {
    @Volatile var isForeground: Boolean = false
        private set

    fun onForeground() { isForeground = true }
    fun onBackground() { isForeground = false }
}
