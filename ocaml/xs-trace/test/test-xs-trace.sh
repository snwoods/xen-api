set -eux

export PATH_TO_FILE=$(pwd)

./test_xs_trace.exe &

PID=$!

../xs_trace.exe cp test-source.json file://$PATH_TO_FILE/test-socket

if [ $(diff test-source.json test-http-server.out) -ne 0 ]
then
    exit 1
fi

rm test-http-server.out

../xs_trace.exe cp test-source.ndjson file://$PATH_TO_FILE/test-socket

if [ $(diff test-source.ndjson test-http-server.out) -ne 0 ]
then
    exit 1
fi

rm test-http-server.out

../xs_trace.exe cp test-source.ndjson.zst file://$PATH_TO_FILE/test-socket

if [ $(diff test-source.ndjson test-http-server.out) -ne 0 ]
then
    exit 1
fi

kill $PID
