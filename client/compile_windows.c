#include <stdio.h>
#include <stdlib.h>
#include <windows.h>
#include <string.h>



int main(void) {
    FILE *file = fopen("cloudflared.exe", "rb");;

    if (file) {
        printf("Cloudflared executable found.\n");
        fclose(file);
        
        char cmd[256];
        snprintf(cmd, sizeof(cmd), "cloudflared.exe access tcp --hostname %s --url localhost:1080", HOST);
        system(cmd);
    }
    else {
        printf("Cloudflared executable not found.\n");
        int result = MessageBoxA(NULL, "Cloudflared executable not found. Do you want to download it?", "Error", MB_ICONERROR | MB_YESNO);
        if (result == IDYES) {
            system("curl -L -o cloudflared.exe https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe");
        }
    }
    return 0;
}
