#include "ruby.h"

#include <atomic>
#include "timestamp.hh"

class PeriodicThread {
    pthread_t pthread;
    TimeStamp interval;

    pthread_mutex_t running_mutex = PTHREAD_MUTEX_INITIALIZER;
    pthread_cond_t running_cv;
    std::atomic_bool running;

    public:
        PeriodicThread(TimeStamp interval) : interval(interval), running(false) {
            pthread_condattr_t attr;
            pthread_condattr_init(&attr);
#if HAVE_PTHREAD_CONDATTR_SETCLOCK
            pthread_condattr_setclock(&attr, CLOCK_MONOTONIC);
#endif
            pthread_cond_init(&running_cv, &attr);
        }

        void set_interval(TimeStamp timestamp) {
            interval = timestamp;
        }

        static void *thread_entrypoint(void *arg) {
            static_cast<PeriodicThread *>(arg)->run();
            return NULL;
        }

        void run() {
#if HAVE_PTHREAD_SETNAME_NP
#ifdef __APPLE__
        pthread_setname_np("Vernier profiler");
#else
        pthread_setname_np(pthread_self(), "Vernier profiler");
#endif
#endif

            TimeStamp next_sample_schedule = TimeStamp::Now();
            bool done = false;
            while (!done) {
                TimeStamp sample_complete = TimeStamp::Now();

                run_iteration();

                next_sample_schedule += interval;

                if (next_sample_schedule < sample_complete) {
                    next_sample_schedule = sample_complete + interval;
                }

                pthread_mutex_lock(&running_mutex);
                if (running) {
#if HAVE_PTHREAD_CONDATTR_SETCLOCK
                    struct timespec next_sample_ts = next_sample_schedule.timespec();
#else
                    auto offset = TimeStamp::NowRealtime() - TimeStamp::Now();
                    struct timespec next_sample_ts = (next_sample_schedule + offset).timespec();
#endif
                    int ret;
                    do {
                        ret = pthread_cond_timedwait(&running_cv, &running_mutex, &next_sample_ts);
                    } while(running && ret == EINTR);
                }
                done = !running;
                pthread_mutex_unlock(&running_mutex);
            }
        }

        virtual void run_iteration() = 0;

        void start() {
            pthread_mutex_lock(&running_mutex);
            if (!running) {
                running = true;

                int ret = pthread_create(&pthread, NULL, &thread_entrypoint, this);
                if (ret != 0) {
                    perror("pthread_create");
                    rb_bug("VERNIER: pthread_create failed");
                }
            }
            pthread_mutex_unlock(&running_mutex);
        }

        void stop() {
            pthread_mutex_lock(&running_mutex);
            bool was_running = running;
            if (running) {
                running = false;
                pthread_cond_broadcast(&running_cv);
            }
            pthread_mutex_unlock(&running_mutex);
            if (was_running)
                pthread_join(pthread, NULL);
            pthread = 0;
        }
};

