FROM alpine
COPY hello.txt /hello.txt
CMD ["cat", "/hello.txt"]
