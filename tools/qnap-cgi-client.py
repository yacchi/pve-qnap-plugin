#!/usr/bin/env python3
"""Minimal client for the gRPC service exposed by the QNAP CSI sidecar.

Message types are built at runtime from a serialized FileDescriptorProto, so
neither protoc nor generated code is required.

usage: qnap-cgi-client.py <Method> '<json request>'
       qnap-cgi-client.py --list
"""
import json
import sys

import grpc
from google.protobuf import descriptor_pb2, descriptor_pool, json_format, message_factory

SOCK = "unix:///sock/cgi-server.sock"
SERVICE = "protobuf.QtsCgiService"

pool = descriptor_pool.DescriptorPool()
fd = descriptor_pb2.FileDescriptorProto()
fd.MergeFromString(open("/work/qts_cgi.desc", "rb").read())
pool.Add(fd)
svc = pool.FindServiceByName(SERVICE)


def cls(full_name):
    return message_factory.GetMessageClass(pool.FindMessageTypeByName(full_name))


def main():
    if sys.argv[1] == "--list":
        for m in svc.methods:
            print(f"{m.name}({m.input_type.full_name}) -> {m.output_type.full_name}")
        return

    method = svc.FindMethodByName(sys.argv[1])
    if method is None:
        sys.exit(f"unknown method: {sys.argv[1]}")

    # Accept @file so credentials never appear in the process list.
    arg = sys.argv[2]
    body = open(arg[1:]).read() if arg.startswith("@") else arg
    if len(sys.argv) > 3:  # merge extra fields on top of the @file base
        merged = json.loads(body)
        merged.update(json.loads(sys.argv[3]))
        body = json.dumps(merged)
    req = json_format.Parse(body, cls(method.input_type.full_name)())
    with grpc.insecure_channel(SOCK) as ch:
        rpc = ch.unary_unary(
            f"/{SERVICE}/{method.name}",
            request_serializer=lambda m: m.SerializeToString(),
            response_deserializer=cls(method.output_type.full_name).FromString,
        )
        try:
            resp = rpc(req, timeout=120)
        except grpc.RpcError as e:
            print(json.dumps({"grpc_error": e.code().name, "detail": e.details()},
                             ensure_ascii=False))
            sys.exit(1)
    print(json_format.MessageToJson(resp, ensure_ascii=False))


if __name__ == "__main__":
    main()
