// Independent echo host for an external ENet reference. Not a package target.
#include <enet/enet.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <netinet/in.h>

int main(int argc, char **argv) {
    size_t channels = argc > 1 ? (size_t)atoi(argv[1]) : 48;
    if (enet_initialize() != 0) return 1;
#ifdef MOONLIGHT_ENET
    struct sockaddr_in native;
    memset(&native, 0, sizeof(native));
    native.sin_family = AF_INET;
    ENetAddress address;
    if (enet_address_set_address(&address, (struct sockaddr *)&native, sizeof(native)) != 0) return 2;
    ENetHost *host = enet_host_create(AF_INET, &address, 1, channels, 0, 0);
#else
    ENetAddress address = { ENET_HOST_ANY, 0 };
    ENetHost *host = enet_host_create(&address, 1, channels, 0, 0);
#endif
    if (!host) return 2;
    host->mtu = 900;
    ENetAddress bound;
    if (enet_socket_get_address(host->socket, &bound) != 0) return 3;
#ifdef MOONLIGHT_ENET
    printf("%u\n", ntohs(((struct sockaddr_in *)&bound.address)->sin_port));
#else
    printf("%u\n", bound.port);
#endif
    fflush(stdout);
    for (;;) {
        ENetEvent event;
        if (enet_host_service(host, &event, 5) < 0) return 4;
        if (event.type == ENET_EVENT_TYPE_CONNECT) enet_peer_timeout(event.peer, 2, 10000, 10000);
        if (event.type == ENET_EVENT_TYPE_RECEIVE) {
            if (enet_peer_send(event.peer, event.channelID, event.packet) != 0) {
                enet_packet_destroy(event.packet); return 5;
            }
            enet_host_flush(host);
        }
    }
}
