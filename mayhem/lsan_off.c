// Leak detection is off for every target (ASan memory-safety checks stay on).
int __lsan_is_turned_off(void) { return 1; }
