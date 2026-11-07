#if defined(_WIN32)
__declspec(dllexport)
#endif
int andemo_answer(int x) { return x + 42; }
