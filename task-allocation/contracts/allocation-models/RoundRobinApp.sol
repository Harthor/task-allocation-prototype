pragma solidity ^0.4.24;

import "@aragon/os/contracts/apps/AragonApp.sol";
import "@aragon/os/contracts/lib/math/SafeMath.sol";

import "../BaseTaskAllocation.sol";

contract RoundRobinApp is AragonApp, BaseTaskAllocation {
    using SafeMath for uint256;

    /// Events
    event TaskCreated(bytes32 indexed taskId);
    event TaskAccepted(bytes32 indexed userId, bytes32 indexed taskId);
    event TaskRejected(bytes32 indexed userId, bytes32 indexed taskId);
    event TaskAllocated(bytes32 indexed userId, bytes32 indexed taskId, bytes32 previousUserId);
    event UserRegistered(bytes32 indexed userId);

    ///Types
    enum Status {
        NonExistent,
        Available,
        Assigned,
        Accepted,
        Rejected,
        Completed
    }

    mapping(bytes32 => Task) tasks;

    mapping(bytes32 => User) users;
    //Need it to transvers users array more gracefuly. 
    mapping(uint256 => bytes32) private userIndex;
    uint256 private userIndexLength;

    //To keep record of user's assignments. Users only can have 1 task assigned.
    /*
     * Key: userId
     */
    mapping(bytes32 => bool) userTaskRegistry;

    uint256 public reallocationTime;

    struct User {
        uint256 index;
        uint256 benefits;
        bool available;
        bool exists;
        mapping(uint256 => bytes32) allocatedTasks;
        uint256 allocatedTasksLength;
    }

    struct Task {
        uint256 userIndex;
        uint256 allocationIndex;
        uint256 endDate;
        Status status;
        // bytes32 languageGroup;
        mapping(bytes32 => bool) rejecters;
    }

    uint8 constant public MAX_ALLOCATED_TASKS = 3;

    ///Errors
    string private constant ERROR_ASSIGNED_TASK = "TASK_ALREADY_ASSIGNED";
    string private constant ERROR_USER_HAS_TASK = "USER_HAS_TASK";
    string private constant ERROR_USER_ALREADY_EXISTS = "USER_ALREADY_EXISTS";
    string private constant ERROR_USER_DONT_EXIST = "USER_DONT_EXIST";
    string private constant ERROR_TASK_EXISTS = "TASK_EXISTS";
    string private constant ERROR_TASK_DONT_EXIST = "TASK_DONT_EXIST";
    string private constant ERROR_TASK_ALLOCATION = "TASK_ALLOCATION_FAIL";
    string private constant ERROR_TASK_NOT_ASSIGNED_TO_USER = "TASK_NOT_ASSIGNED_TO_USER";
    string private constant ERROR_USER_HAS_TOO_MANY_TASKS = "USER_HAS_TOO_MANY_TASKS";

    modifier userHasNoTask(bytes32 _userId) {
        require(!userTaskRegistry[_userId], ERROR_USER_HAS_TASK);
        _;
    }

    modifier userDontExist(bytes32 _userId) {
        require(!users[_userId].exists, ERROR_USER_ALREADY_EXISTS);
        _;
    }

    modifier userExists(bytes32 _userId) {
        require(users[_userId].exists, ERROR_USER_DONT_EXIST);
        _;
    }

    modifier taskDontExist(bytes32 _taskId) {
        require(tasks[_taskId].status == Status.NonExistent, ERROR_TASK_EXISTS);
        _;
    }

    modifier taskExists(bytes32 _taskId) {
        require(tasks[_taskId].status != Status.NonExistent, ERROR_TASK_DONT_EXIST);
        _;
    }

    modifier taskAssigned(bytes32 _taskId, bytes32 _userId) {
        Task memory task = tasks[_taskId];
        bytes32 userId = userIndex[task.userIndex];
        require(task.status == Status.Assigned && _userId == userId, ERROR_TASK_NOT_ASSIGNED_TO_USER);
        _;
    }

    modifier tooManyTasks(bytes32 _userId) {
        require(users[_userId].allocatedTasksLength <=  MAX_ALLOCATED_TASKS, ERROR_USER_HAS_TOO_MANY_TASKS);
        _;
    }

    function initialize() public onlyInit {
        initialized();
        // reallocationTime = 1800;
        reallocationTime = 90;
    }

    function restart() external {
        emit TasksRestart(msg.sender);
    }

    function registerUser(bytes32 _userId)
    external
    userDontExist(_userId)
    {
        userIndex[userIndexLength] = _userId;
        users[_userId].index = userIndexLength;
        users[_userId].available = true;
        users[_userId].exists = true;
        userIndexLength = userIndexLength.add(1);

        emit UserRegistered(_userId);
    }

    /**
     * @notice Create a new assignment.
     * @param _taskId The task's id.
     */
    function createTask(
        // bytes32 _languageGroup,
        bytes32 _taskId
    )
    external
    taskDontExist(_taskId)
    {
        Task storage task = tasks[_taskId];
        task.status = Status.Available;

        emit TaskCreated(_taskId);
    }

    function allocateTask(
        bytes32 _taskId,
        bytes32 _userId
    )
    external
    taskExists(_taskId)
    userExists(_userId)
    {
        bool allocated = addUserAllocatedTask(_userId, _taskId);
        require(allocated, ERROR_TASK_ALLOCATION);
        emit TaskAllocated(_userId, _taskId, 0);
    }

    function acceptTask(
        bytes32 _userId,
        bytes32 _taskId
    )
    external
    userExists(_userId)
    taskAssigned(_taskId, _userId)
    userHasNoTask(_userId)
    {
        tasks[_taskId].status = Status.Accepted;
        userTaskRegistry[_userId] = true;
        //Can't access mapping inside user struct
        //unless It's declare using storage keyword.
        User storage user = users[_userId];
        bytes32 currentTaskId;
        //Reallocated all user available tasks.
        for (uint i = 0; i < user.allocatedTasksLength; i++) {
            currentTaskId = user.allocatedTasks[i];
            if (currentTaskId != _taskId) {
                reallocateTask(currentTaskId);
            }
        }
        emit TaskAccepted(_userId, _taskId);
    }

    function rejectTask(
        bytes32 _userId,
        bytes32 _taskId
    )
    external
    userExists(_userId)
    taskAssigned(_taskId, _userId)
    {
        tasks[_taskId].rejecters[_userId] = true;
        emit TaskRejected(_userId, _taskId);
        reallocateTask(_taskId);
    }

    function reallocateTask(
        bytes32 _taskId
    )
    public
    taskExists(_taskId)
    {
        Task storage task = tasks[_taskId];
        uint oldUserIndex = task.userIndex;
        bytes32 oldUserId = userIndex[oldUserIndex];
        uint newUserIndex = oldUserIndex.add(1);
        bool assigneeFounded = false;
        uint userCounter = 0;

        deleteUserAllocatedTask(oldUserId, _taskId);
        while (userCounter < userIndexLength && !assigneeFounded) {
            if (newUserIndex == userIndexLength) {
                newUserIndex = 0;
            }
            bytes32 currUserId = userIndex[newUserIndex];
            User memory currUser = users[currUserId];
            assigneeFounded = addUserAllocatedTask(currUserId, _taskId);
            if (assigneeFounded) {
                emit TaskAllocated(userIndex[newUserIndex], _taskId, oldUserId);
            } else {
                userCounter = userCounter.add(1);
                newUserIndex = newUserIndex.add(1);
            }
        }
        if (!assigneeFounded) {
            task.status = Status.Rejected;
        }
    }

    function addUserAllocatedTask(
        bytes32 _userId,
        bytes32 _taskId
    )
    private
    returns (bool)
    {
        User storage user = users[_userId];
        Task storage task = tasks[_taskId];

        // User doesn't have a task already and didn't reject current task.
        if (user.available && !userTaskRegistry[_userId] && !task.rejecters[_userId]
            && user.allocatedTasksLength <=  MAX_ALLOCATED_TASKS) {

            user.allocatedTasks[user.allocatedTasksLength] = _taskId;
            task.allocationIndex = user.allocatedTasksLength;
            user.allocatedTasksLength = user.allocatedTasksLength.add(1);

            task.userIndex = user.index;
            task.status = Status.Assigned;
            task.endDate = block.timestamp.add(reallocationTime);

            return true;
        }
        return false;
    }

    function deleteUserAllocatedTask(
        bytes32 _userId,
        bytes32 _taskId
    )
    private
    {
        User storage user = users[_userId];
        uint256 lastTaskIndex;
        bytes32 lastTask;
        uint256 allocatedTaskIndex = tasks[_taskId].allocationIndex;
        if(user.allocatedTasksLength > 0) {
            lastTaskIndex = user.allocatedTasksLength.sub(1);

        }
        else {
            lastTaskIndex = user.allocatedTasksLength;
        }
        lastTask = user.allocatedTasks[lastTaskIndex];
        user.allocatedTasksLength = lastTaskIndex;
        user.allocatedTasks[allocatedTaskIndex] = lastTask;
    }

    function getUser(
        bytes32 _userId
    )
    external
    view
    returns (
        bool available,
        uint256 benefits
    )
    {
        User memory user = users[_userId];
        available = user.available;
        benefits = user.benefits;
    }

    function getTask(bytes32 _taskId)
    external
    view
    taskExists(_taskId)
    returns (
        uint256 endDate,
        Status status
    ) 
    {
        Task memory task = tasks[_taskId];
        endDate = task.endDate;
        status = task.status;
    }
}
