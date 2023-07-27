main :: () {
    success: bool;
    
    dir := path_strip_filename(get_path_of_running_executable());
    logs_dir = sprint("%logs", dir);
    dir_existed := file_exists(logs_dir);
    
    make_directory_if_it_does_not_exist(logs_dir);
    timestamp := to_nanoseconds(current_time_consensus());
    if !dir_existed then write_entire_file(tprint("%/%", logs_dir, timestamp), "");
    
    update_logs_list();
    // Load data from logs to hash tables. Do not compact newly created file
    for 1..logs_list.count-1 {
        success = compaction_file(*logs_list[it], load=true);
        if !success return;
    }
    
    // Merge segments !
    // if log_list.count > 2 {
    //     merged_file := merge_segments(log_list[0], log_list[1]);
    // }
    
    current_log = logs_list.count - 1; // the newest
   
    // Start thread for compaction of key-value update log, retaining only the most recent value for each key
    compaction_thread_group = Thread_Group.{};
    init(*compaction_thread_group, 1, compaction_proc);
    compaction_thread_group.name = "Compaction";
    start(*compaction_thread_group);
    
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
                reply := tprint("HTTP/1.1 403 Forbidden\r\nContent-Type: text/plain\r\n\r\n%", res);
                write := send(client_socket, reply.data, xx reply.count, 0);
                closesocket(client_socket);
                continue;
            }
            
            reply := "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n";
            if res != "" {
                reply = tprint("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n%", res);
            }
            write := send(client_socket, reply.data, xx reply.count, 0);
            if write == SOCKET_ERROR {
                print("send failed %\n", WSAGetLastError());
            }
            free(res);
        } else if read == 0 {
            print("Connection closing.. \n");
        } else {
            print("recv failed %\n", WSAGetLastError());
        }
        closesocket(client_socket);
    }
        
    // Close
    closesocket(listen_socket);
    if compaction_thread_group.initted then shutdown(*compaction_thread_group);
}

compaction_proc :: (group: *Thread_Group, thread: *Thread, work: *void) -> Thread_Continue_Status {
    compaction := cast(*Compaction) work;        
    compaction_file(*logs_list[compaction.log_index], load=true);
    return .CONTINUE;
}

create_new_log :: () -> (int, bool) {
    log: Log;
    success: bool;
    log.modification_time = current_time_consensus();
    timestamp := to_nanoseconds(log.modification_time);
    log.name = sprint("%/%", logs_dir, timestamp);
    array_add(*logs_list, log);
    return logs_list.count-1, true;
}

maybe_create_new_file :: (file_name: string) -> (int, bool) {
    file_modified_time,file_size, ok := file_modtime_and_size(file_name); 
    if file_size > SEGMENT_SIZE {
        print("new file\n");
        success: bool;
        current_log, success = create_new_log();
        if !success {
            print("error creating file\n");
            return -1, false;
        }
        return current_log, true;
    }
    return -1, false;
}

merge_segments :: (file_path_1: string, file_path_2: string) -> (string, bool) {
    data: Table(string, string);
    
    upload_to_data_table :: (file_path: string, data: Table) -> bool {
        file_contents_str, ok := read_entire_file(file_path);
        if !ok return false;
        
        k_v_list := split(file_contents_str, ";");
        for k_v: k_v_list {
            ok, key, value := split_from_left(k_v, ":");
            table_set(*data, copy_string(key), copy_string(value));
        }
        
        return true;
    } 
    
    upload_to_data_table(file_path_1, data);
    upload_to_data_table(file_path_2, data);
    
    timestamp := to_nanoseconds(current_time_consensus());
    new_file_path := sprint("%/%", logs_dir, timestamp);
    return new_file_path, true;
}

update_logs_list :: () {
    array_reset_keeping_memory(*logs_list);
    
    maybe_add_to_logs_list :: (file_info: *File_Visit_Info, userdata: *void) {
        log := Log.{name=copy_string(file_info.full_name), modification_time=file_info.modification_time};
        array_add(*logs_list, log);
    }
    visit_files(logs_dir, recursive = false, null, maybe_add_to_logs_list, visit_directories = false);
    
     // Sort log files by modified time
    compare_file_modification_time :: (log1: Log, log2: Log) -> s64 {
        if log1.modification_time > log2.modification_time return 1;
        if log2.modification_time > log1.modification_time return -1;
        return 0;
    }
    quick_sort(logs_list, compare_file_modification_time);
}

compaction_file :: (log: *Log, load: bool = false) -> bool {
    data: Table(string, string);
    file_path := log.name;
    
    f, ok2 := file_open(file_path);
    if !ok2 {
        print("Compaction: Could not open key-value storage file\n");
        return false;
    }
    file_contents_str, ok := read_entire_file(file_path);
    if !ok return  false;
    file_close(*f);
    
    k_v_list := split(file_contents_str, ";");
    for k_v: k_v_list {
        ok, key, value := split_from_left(k_v, ":");
        table_set(*data, copy_string(key), copy_string(value));
    }
    
    left, right : string;
    timestamp: int;
    ok, left, right = split_from_right(file_path, "/");
    timestamp, ok = string_to_int(right);
    new_log_name := sprint("%/%", logs_dir, timestamp+1);
        
    table_reset(*log.indexes);
    for line: data.entries {
        if line.key == "" continue;
        if load load_to_hash_table(line.key, line.value, log, new_log_name);
        ok := write_key_value_pair_to_file(line.key, line.value, new_log_name);
        if !ok return false;
    }
    log.name = new_log_name; 
    // log.modification_time = current_time_consensus();
    file_delete(file_path);  
    return true;
}

parse_http_request :: (request: string) -> (bool, string) {
    ok, method, right := split_from_left(request, " ");
    if method != "POST" return false, "Wrong method. Should be POST.";
    
    left: string;
    ok, left, right = split_from_left(request, "Content-Type: ");
    if !ok return false, "Content type missed";
    content_type, instruction: string;
    ok, content_type, right = split_from_left(right, "\n");
    if trim(content_type) != "text/plain" return false, "Wrong content type";
    ok, left, right = split_from_left(right, "\r\n\r\n");
    content := trim(right);
    
    ok, instruction, right = split_from_left(content, " ");
    if instruction == {
    
        case "set";
            print("SET logs.list count %\n", logs_list.count);
            k_v := split(right, " ");
            if k_v.count != 2 return false, "Incorrect request format. Please use the format 'set KEY VALUE'.";
            ok := handle_set(k_v[0], k_v[1], *logs_list[current_log]);
            return ok, "";
            
        case "get";                                
            k_v := split(right, " ");
            if k_v.count != 1 return false, "Incorrect request format. Please use the format 'get KEY'.";
            ok, value := handle_get(k_v[0]);
            return ok, value;
            
        case "cat";
            result: String_Builder;
            init_string_builder(*result);
            for logs_list {
                f, ok := file_open(it.name, for_writing=true, keep_existing_content=true);
                if !ok {
                    print("Cat: Could not open key-value storage file\n");
                    return false, "";
                }
                file_contents_str, ok2 := read_entire_file(it.name);
                if !ok2 return  false, "";
                print_to_builder(*result, file_contents_str);
                file_close(*f);
            }
            str := builder_to_string(*result);
            return true, str;
    }
    return false, "";
}

write_key_value_pair_to_file :: (key: string, value: string, file_path: string) -> bool{
    file, ok := file_open(file_path, for_writing=true, keep_existing_content=true);
    if !ok {
        print("Open file to write: Could not open key-value storage file\n");
        return false;
    }
    defer file_close(*file);
    
    data := tprint("%:%;", key, value);
    advance :=  file_length(file);
    file_set_position(file, advance);
    success :=  file_write(*file, data);
    if !success {
        print("Could not write to key-value storage file.\n");
        return false;
    }
    return true;
}

load_to_hash_table :: (key: string, value: string, log: Log, file_path: string) {
    file, ok := file_open(file_path, for_writing=true, keep_existing_content=true);
    if !ok {
        print("Open file to write: Could not open key-value storage file\n");
    }
    advance := file_length(file);
    file_close(*file);
    offset := xx(advance + key.count + 1);
    
    offset_info: [2]u32;
    offset_info[0] = xx offset;
    offset_info[1] = xx value.count;
    table_set(*log.indexes, copy_string(key), offset_info);
}

handle_set :: (key: string, value: string, log: *Log) -> bool {
    load_to_hash_table(key, value, <<log, log.name);
    ok := write_key_value_pair_to_file(key, value, log.name);    
    if !ok return false;
    // if current file is too big, create a new one
    index, success := maybe_create_new_file(log.name);
    if success {
        // Give the thread group compaction work
        work := New(Compaction);
        work.log_index = index-1;
        work.input_number = 10;
        add_work(*compaction_thread_group, work, tprint("Work item %", work));
        current_log = index;
    }
    return true;
}

handle_get :: (key: string) -> (bool, string) {
    for < logs_list.count-1..0 {
        log := logs_list[it];    
        offset, ok := table_find(*log.indexes, key);
        if !ok continue;
                
        advance, length := offset[0], offset[1];
        
        buffer := cast(*u8) alloc(length); // Free!
        value: string;
        value.count = length;
        value.data = buffer;
        
        file, ok2 := file_open(log.name, for_writing=true, keep_existing_content=true);
        if !ok2 {
            print("Write to file: Could not open key-value storage file\n");
            return false, "";
        }
        defer file_close(*file);
    
        file_set_position(file, advance);     
        success, bytes :=  file_read(file, buffer, length);
        if !success {
            print("Could not read from key-value storage file.\n");
            return false, "no value";
        }
        return true, value;
    } 
    return false, "no value";
}

Compaction :: struct {
    log_index: int;

    input_number: u64; 
    output_sum:   u64;
}
compaction_thread_group: Thread_Group;


Log :: struct {
    indexes: Table(string, [2]u32);
    name: string;
    modification_time: Apollo_Time;
}
logs_list: [..]Log;
current_log: int;
logs_dir : string;


DEFAULT_PORT :: "27015";
DEFAULT_BUFLEN :: 1024;
SEGMENT_SIZE :: 32;

#import "Basic";
#import "Socket";
#import "String";
#import "Hash_Table";
#import "File";
#import "File_Utilities";
#import "System";
#import "Sort";
#import "Thread";




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