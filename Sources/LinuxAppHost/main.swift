import LinuxHostApp

// The app's library, linked in when the package was built with
// LINUXAPPRUNTIME_APP_LIBRARY, defines these.
#if APP_LINKED
HostApp.main(AppEntryPoints(main: rt_main, dispatch: rt_dispatch, finalize: rt_finalize))
#else
HostApp.main(nil)
#endif
