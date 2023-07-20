main :: () {
    // create file
    success: bool;
    file_name := "C:/Users/olya/projects/data_storage/file1.kv";
    file, success =  file_open(file_name, for_writing=true, keep_existing_content=true);
    if !success {
        print("Could not open key-value storage file\n");
        return;
    }
    
    wsa_data : WSAData;
    
    b1: u8 = 0x2;
    b2: u8 = 0x2;
    w : u16 = (cast(u16)b1) << 8 | cast(u16)b2;
    
    // Initialize Winsock
    wVersionRequested := w;
    res := WSAStartup(wVersionRequested, *wsa_data);
    
    result : *ADDRINFOA;
    hints : addrinfo;
    hints.ai_socktype = .SOCK_STREAM;
    hints.ai_protocol = .TCP;
    hints.ai_flags =  .PASSIVE;
    hints.ai_family = AF_INET;
    
    address_info := getaddrinfo(null, DEFAULT_PORT, *hints, *result);
    if address_info != 0 {
        print("getaddrinfo failed %\n", address_info);
        return;
    }
    
    // Create socket: socket exists in namespace, but it has no name assigned to it.  
    listen_socket := INVALID_SOCKET;
    listen_socket = socket(result.ai_family, result.ai_socktype, result.ai_protocol);
    
    if listen_socket == INVALID_SOCKET {
        print("socket failed\n");
        return;
    }
    
       
    // Bind to establish the local association of the socket by assigning a local name to an unnamed socket.
    // Name = address family + host address + port number
    // Client applications use the IP address and port to connect to the host network.
    
    // Bind the listening socket using theinformation in the sockaddr structure
    r := bind(listen_socket, result.ai_addr, xx result.ai_addrlen);
    if r < 0 {
        print("bind failed \n");
        freeaddrinfo(result);
        closesocket(listen_socket);
        return;
    }
    
    // Listen
    if listen(listen_socket, SOMAXCONN) == SOCKET_ERROR {
        print("listen failed with error: ", WSAGetLastError());
        closesocket(listen_socket);
        return;
    }
    
    while true {
        // Accept: handle connnection requests on that socket
        client_socket := INVALID_SOCKET;
        client_socket = accept(listen_socket, null, null);
        if client_socket == INVALID_SOCKET {
            print("accept failed \n");
            closesocket(listen_socket);
            return;
        } 
        
        // Read & Write
        recvbuf : [DEFAULT_BUFLEN]u8;
        read := recv(client_socket, recvbuf.data, xx recvbuf.count, 0);

        if read > 0 {
            str: string;
            str.data = recvbuf.data;
            str.count = read;
            
            ok, res := parse_http_request(str);
            if !ok {
                print("wrong request format\n");
                reply := "HTTP/1.1 403 Forbidden\r\nContent-Type: text/plain\r\nAge: 30\r\n\r\nWrong request format!";
                write := send(client_socket, reply.data, xx reply.count, 0);
                closesocket(client_socket);
                continue;
            }
            
            reply := "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n";
            if res != "" {
                reply = tprint("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n%", res);
                free(res);
            }
            write := send(client_socket, reply.data, xx reply.count, 0);
            if write == SOCKET_ERROR {
                print("send failed %\n", WSAGetLastError());
            }
        } else if read == 0 {
            print("Connection closing.. \n");
        } else {
            print("recv failed %\n", WSAGetLastError());
        }
        closesocket(client_socket);
    }
        
    // Close
    closesocket(listen_socket);
    file_close(*file);
}

parse_http_request :: (request: string) -> bool, string {
    ok, method, right := split_from_left(request, " ");
    if method != "POST" return false, "";
    
    left: string;
    ok, left, right = split_from_left(request, "Content-Type: ");
    if !ok {
        print("content type missed\n");
        return false, "";
    }
    content_type, instruction: string;
    ok, content_type, right = split_from_left(right, "\n");
    if trim(content_type) != "text/plain" {
        print("wrong content type\n");
        return false, "";
    }
    
    ok, left, right = split_from_left(right, "\r\n\r\n");
    content := trim(right);
    
    ok, instruction, right = split_from_left(content, " ");
    success : bool;
    if instruction == {
    
        case "set";
            k_v := split(right, " ");
            if k_v.count != 2 return false, "";
            
            // write to key_value storage file
            data := tprint("'%':%;", k_v[0], k_v[1]);
            advance :=  file_length(file);
            file_set_position(file, advance);
            success =  file_write(*file, data);
            if !success {
                print("Could not write to key-value storage file.\n");
                return false, "";
            }
            offset: [2]u32;
            offset[0] = xx (advance + k_v[0].count + 3);
            offset[1] = xx k_v[1].count;
            table_set(*indexes, copy_string(k_v[0]), offset);
            return true, "";
            
        case "get";                                
            k_v := split(right, " ");
            if k_v.count != 1 return false, "";
            
            offset: [2]u32;
            offset, ok = table_find(*indexes, k_v[0]);
            advance, length := offset[0], offset[1];
            if !ok return true, "no value";
            
            buffer := cast(*u8) alloc(length);
            value : string;
            value.count = length;
            value.data = buffer;
            
            file_set_position(file, advance);
            success =  file_read(file, buffer, length);
            if !success {
                print("Could not read from key-value storage file.\n");
                return false, "";
            }
            
            return true, value;
    }
    return false, "";
}

indexes: Table(string, [2]u32);
file: File;

DEFAULT_PORT :: "27015";
DEFAULT_BUFLEN :: 1024;

#import "Basic";
#import "Socket";
#import "String";
#import "Hash_Table";
#import "File";




// Multiple clients

 // client_sockets: [MAX_CLIENTS]s32;
 //    read_set: fd_set;
    
 //    // Initialize all client socket to 0 so not checked
 //    for client: client_sockets client = 0;
 //    max_sd: s32;
    
 //    while true {
 //        // clear the socket set
 //        for fd: read_set.fd_array fd = 0;
 //        read_set.fd_count = 0;
        
 //        // add master socket to set
 //        read_set.fd_array[read_set.fd_count] = listen_socket;
 //        read_set.fd_count += 1;
 //        max_sd = xx listen_socket;
        
 //        for client: client_sockets {
 //            sd := client;
            
 //            //if valid socket descriptor then add to read list 
 //            if sd > 0 read_set.fd_array[read_set.fd_count] = xx client;
 //            read_set.fd_count += 1;
            
 //            //highest file descriptor number, need it for the select function 
 //            if sd > max_sd then max_sd = sd;
 //        }
        
 //        for r: read_set.fd_array {print("%\n", r);}
        
 //        // wait for an activity on one of the sockets , timeout is NULL ,so wait indefinitely 
 //        socket_count := select(max_sd + 1, *read_set, null, null, null);
 //        print("Activity %\n", activity);
 //        if socket_count == SOCKET_ERROR {
 //            print("select failed with error \n");
 //        }
        
 //        //If something happened on the master socket, then its an incoming connection 
        
 //    }